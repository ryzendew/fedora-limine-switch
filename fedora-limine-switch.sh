#!/usr/bin/env bash
#
# fedora-limine-switch.sh — Replace GRUB with Limine on Fedora, the idiot-proof way.
#
# What it does (UEFI-first, BIOS supported):
#   1. Preflight: Fedora check, root check, UEFI/BIOS, Secure Boot, ESP, free space,
#      kernel layout, GRUB state. Backs everything up before touching anything.
#   2. Installs deps via dnf (efibootmgr, curl, tar, etc. + optional extras).
#   3. Downloads official Limine binary release (default: latest, fallback 12.9.3),
#      deploys BOOTX64.EFI -> EFI/limine/limine_x64.efi (+ optional fallback).
#   4. Creates /etc/default/limine (CachyOS-style knobs), installs a kernel-install
#      hook (95-limine.install) + generator (limine-fedora-sync) so every
#      `dnf update` that installs a kernel auto-syncs the ESP + regenerates
#      limine.conf. This is the Fedora equivalent of CachyOS's
#      limine-mkinitcpio-hook / limine-dracut-support pacman hooks.
#   5. Syncs current kernels (/boot/vmlinuz-*, /boot/initramfs-*.img) to
#      $ESP/<machine-id>/<version>/ (FAT-readable, since Limine reads ONLY
#      FAT12/16/32 + ISO9660 — it can NOT read Fedora's default ext4/xfs /boot).
#   6. Generates limine.conf with per-kernel entries, rescue entry, and optional
#      Windows/other-OS (chainload), memtest86+, EDK2 Shell entries.
#   7. Registers "Limine" with efibootmgr and puts it first in BootOrder,
#      KEEPING the old Fedora/GRUB entry as fallback. Rollback = reorder back.
#   8. Optional CachyOS-suite extras: memtest86+, edk2 shell, snapper/btrfs
#      snapshot entries, Catppuccin theme + splash.
#   9. Optional Secure Boot support (opt-in): MOK keygen + sbsign +
#      `limine enroll-config` + per-file hashes, with shim-chainload
#      (idiot-proof, recommended) or custom-db (advanced) methods,
#      including NVIDIA/DKMS unification (one MOK signs Limine EFI +
#      kernel modules) + ESP re-sync after DKMS rebuilds.
#      Off by default; `--yes` never enrolls keys (needs a reboot + password).
#
# GRUB is NEVER removed by default. There is an explicit opt-in step for that.
#
# Usage:
#   sudo ./fedora-limine-switch.sh                 # interactive wizard (recommended)
#   sudo ./fedora-limine-switch.sh --check         # preflight only, no changes
#   sudo ./fedora-limine-switch.sh --update        # re-sync kernels + regenerate limine.conf
#   sudo ./fedora-limine-switch.sh --uninstall     # rollback to GRUB-first
#   sudo ./fedora-limine-switch.sh --sb-setup[=mok-shim|custom-db]  # sign existing install for Secure Boot
#   sudo ./fedora-limine-switch.sh --sb-status     # report Secure Boot state, no changes
#   sudo ./fedora-limine-switch.sh --sb-resign     # re-enroll config hash + re-sign EFIs
#   sudo ./fedora-limine-switch.sh --yes           # non-interactive (sane defaults, never enrolls SB keys)
#   sudo ./fedora-limine-switch.sh --dry-run       # print what WOULD be done
#
# Tested on: Fedora 41/42/43/45 (x86_64, UEFI). BIOS path is best-effort.
# Limine docs: https://github.com/Limine-Bootloader/Limine/blob/trunk/USAGE.md
#
set -euo pipefail

# ---------------------------------------------------------------- config ----

LIMINE_FALLBACK_VERSION="12.9.3"
LIMINE_GITHUB_API="https://api.github.com/repos/Limine-Bootloader/Limine/releases/latest"
LIMINE_BINARY_URL_TMPL="https://github.com/Limine-Bootloader/Limine/releases/download/v__VER__/limine-binary.tar.xz"

DEFAULT_ESP_CANDIDATES=("/boot/efi" "/efi" "/boot")
BACKUP_ROOT="/root/fedora-limine-backup"
LOG_FILE="/var/log/fedora-limine-switch.log"
CONFIG_FILE="/etc/default/limine"
MACHINE_ID_FILE="/etc/machine-id"

SYNC_SCRIPT="/usr/local/sbin/limine-fedora-sync"
UPDATE_WRAPPER="/usr/local/sbin/limine-update"
HOOK_FILE="/etc/kernel/install.d/95-limine.install"
LIMINE_TOOL="/usr/local/bin/limine"
SB_KEY_DIR_DEFAULT="/etc/limine/keys"

DRY_RUN=0
ASSUME_YES=0
MODE="install"
SB_SETUP_METHOD="ask"

# ---------------------------------------------------------------- colors ----

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[34m'
  C_MAG=$'\e[35m'; C_CYN=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_MAG=""; C_CYN=""; C_BLD=""; C_RST=""
fi

log()  { echo "${C_CYN}[*]${C_RST} $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[*] $*"; }
ok()   { echo "${C_GRN}[OK]${C_RST} $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[OK] $*"; }
warn() { echo "${C_YLW}[!!]${C_RST} $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[!!] $*"; }
err()  { echo "${C_RED}[XX]${C_RST} $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[XX] $*"; }
die()  { err "$*"; exit 1; }

banner() {
  cat <<'EOF'
  ╔══════════════════════════════════════════════════════╗
  ║   Fedora → Limine switcher  (CachyOS-style suite)    ║
  ║   Idiot-proof. Keeps GRUB as fallback. Undoable.     ║
  ╚══════════════════════════════════════════════════════╝
EOF
}

# ---------------------------------------------------------------- args -----

usage() {
  grep '^#' "$0" | sed -n '/Usage:/,/dry-run/p' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --update|--resync|--sync) MODE="update"; shift ;;
    --uninstall|--rollback|--remove) MODE="uninstall"; shift ;;
    --sb-setup) MODE="sb-setup"; SB_SETUP_METHOD="ask"; shift ;;
    --sb-setup=*) MODE="sb-setup"; SB_SETUP_METHOD="${1#--sb-setup=}"; shift ;;
    --sb-status) MODE="sb-status"; shift ;;
    --sb-resign) MODE="sb-resign"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run|--dryrun|-n) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1 (see --help)"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- helpers --

confirm() {
  local prompt="${1:-Proceed?} [y/N]: "
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "(dry-run: would ask: $prompt)"; return 0; fi
  local ans=""
  read -r -p "$prompt" ans || true
  [[ "$ans" == [yY] || "$ans" == [yY]es ]]
}

ask_with_default() {
  local prompt="$1" def="$2" ans=""
  if [[ "$ASSUME_YES" -eq 1 ]]; then echo "$def"; return; fi
  read -r -p "$prompt [$def]: " ans || true
  echo "${ans:-$def}"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  (dry-run) $*"
  else
    "$@"
  fi
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo $0"
  mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE" 2>/dev/null || LOG_FILE="./fedora-limine-switch.log"
}

is_fedora() { [[ -f /etc/os-release ]] && grep -qi '^ID=fedora' /etc/os-release; }

firmware_type() {
  if [[ -d /sys/firmware/efi ]]; then echo "uefi"; else echo "bios"; fi
}

secureboot_state() {
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null || echo "unknown"
  elif command -v bootctl >/dev/null 2>&1; then
    bootctl status 2>/dev/null | grep -i "Secure Boot" || echo "unknown"
  else
    echo "unknown (install mokutil to check)"
  fi
}

detect_esp() {
  local c target fstype
  for c in "${DEFAULT_ESP_CANDIDATES[@]}"; do
    [[ -e "$c" ]] || continue
    # Strict: candidate must itself be the mountpoint (not just a dir on /).
    target="$(findmnt -n -o TARGET --target "$c" 2>/dev/null | head -n1 || true)"
    [[ "$target" == "$c" ]] || continue
    fstype="$(findmnt -n -o FSTYPE --target "$c" 2>/dev/null || echo ?)"
    # Accept vfat outright; accept anything else only if bootctl agrees later.
    if [[ "$fstype" == "vfat" ]]; then
      echo "$c"
      return 0
    fi
    # Non-vfat mount at an ESP candidate (e.g. /boot on xfs) is NOT the ESP.
    continue
  done
  # Fallback: ask systemd-boot about the ESP.
  if command -v bootctl >/dev/null 2>&1; then
    local p
    p="$(bootctl -p 2>/dev/null | head -n1 | tr -d '\n' || true)"
    if [[ -n "$p" && -d "$p" ]]; then
      echo "$p"
      return 0
    fi
  fi
  return 1
}

esp_source() { findmnt -n -o SOURCE --target "$1" 2>/dev/null | head -n1; }

esp_details() {
  local esp="$1" src disk part
  src="$(esp_source "$esp")"
  echo "ESP mount : $esp"
  echo "ESP source: ${src:-unknown}"
  df -h "$esp" 2>/dev/null | tail -n1 || true
  if [[ -n "${src:-}" ]]; then
    disk="$(lsblk -n -o PKNAME "$src" 2>/dev/null | head -n1 || true)"
    part="$(lsblk -n -o PARTN "$src" 2>/dev/null | head -n1 || true)"
    [[ -n "$disk" ]] && echo "ESP disk  : /dev/$disk  part #: ${part:-?}"
    echo "ESP PARTUUID: $(lsblk -n -o PARTUUID "$src" 2>/dev/null | head -n1 || echo ?)"
    echo "ESP FAT UUID: $(lsblk -n -o UUID "$src" 2>/dev/null | head -n1 || echo ?)"
  fi
}

machine_id() { cat "$MACHINE_ID_FILE" 2>/dev/null | tr -d ' \n' || echo "unknown"; }

fedora_version() {
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  echo "${VERSION_ID:-unknown} (${PRETTY_NAME:-unknown})"
}

list_fedora_kernels() {
  # Canonical list: /boot/vmlinuz-<ver>, newest first by version sort.
  ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v '^0-rescue' | sort -Vr || true
}

rescue_kernel() {
  ls -1 /boot/vmlinuz-0-rescue* 2>/dev/null | head -n1 || true
}

rescue_initramfs() {
  ls -1 /boot/initramfs-0-rescue*.img 2>/dev/null | head -n1 || true
}

kernel_cmdline() {
  # Precedence (matches kernel-install): /etc/kernel/cmdline > /usr/lib/kernel/cmdline > /proc/cmdline minus BOOT_IMAGE
  if [[ -f /etc/kernel/cmdline ]]; then
    cat /etc/kernel/cmdline
  elif [[ -f /usr/lib/kernel/cmdline ]]; then
    cat /usr/lib/kernel/cmdline
  else
    tr ' ' '\n' < /proc/cmdline | grep -v '^BOOT_IMAGE=' | tr '\n' ' ' | sed 's/ *$//'
  fi
}

root_hint() {
  # Prefer the root= token from the running cmdline or /etc/kernel/cmdline.
  local cmd
  cmd="$(kernel_cmdline)"
  if [[ "$cmd" =~ (root=[^[:space:]]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    # Fall back to findmnt UUID
    local uuid
    uuid="$(findmnt -n -o UUID / 2>/dev/null || true)"
    [[ -n "$uuid" ]] && echo "root=UUID=$uuid" || echo "root=/dev/disk/by-uuid/UNKNOWN"
  fi
}

esp_free_mb() {
  df -m --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' '
}

needed_mb_estimate() {
  # Sum of all (vmlinuz + initramfs) + 60MB headroom for Limine + conf + extras.
  local total_kb=0 f
  for f in /boot/vmlinuz-* /boot/initramfs-*.img; do
    [[ -f "$f" ]] || continue
    total_kb=$(( total_kb + $(du -k "$f" 2>/dev/null | cut -f1) ))
  done
  echo $(( total_kb / 1024 + 60 ))
}

latest_limine_version() {
  local ver
  ver="$(curl -fsSL --max-time 15 "$LIMINE_GITHUB_API" 2>/dev/null | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]*"' | head -n1 | sed 's/.*v\([0-9][^"]*\)".*/\1' || true)"
  [[ -n "$ver" ]] && echo "$ver" || echo "$LIMINE_FALLBACK_VERSION"
}

# ---------------------------------------------------------------- preflight

preflight() {
  banner
  echo "Mode: $MODE   (dry-run=$DRY_RUN assume-yes=$ASSUME_YES)"
  echo

  is_fedora || die "This script is for Fedora only (ID=fedora in /etc/os-release)."
  ok "Fedora detected: $(fedora_version)"

  local fw
  fw="$(firmware_type)"
  if [[ "$fw" == "uefi" ]]; then
    ok "Firmware: UEFI (primary supported path)"
  else
    warn "Firmware: legacy BIOS detected. UEFI is recommended; BIOS install is best-effort."
  fi

  echo "--- Secure Boot ---"
  SB_STATE="unknown"
  if secureboot_state | grep -qi enabled; then SB_STATE="enabled"; elif secureboot_state | grep -qi disabled; then SB_STATE="disabled"; fi
  secureboot_state || true
  if [[ "$SB_STATE" == "enabled" ]]; then
    warn "Secure Boot is ENABLED. Upstream Limine is NOT Microsoft-signed."
    echo "  The installer keeps GRUB working and offers opt-in signing later:"
    echo "    - mok-shim (recommended): MOK key + shim chainload, no firmware Setup Mode."
    echo "    - custom-db (advanced): own DB keys + firmware Setup Mode enrollment."
    echo "  See README 'Secure Boot'. You can also pick this post-install:"
    echo "    sudo $0 --sb-setup"
  elif [[ "$SB_STATE" == "disabled" ]]; then
    ok "Secure Boot: disabled — Limine boots unsigned. Signing stays optional:"
    echo "  sudo $0 --sb-setup   (only needed if you plan to re-enable Secure Boot)"
  else
    warn "Secure Boot state unknown (mokutil missing?). Continuing; signing stays optional."
  fi

  echo "--- ESP ---"
  local esp
  esp="$(detect_esp)" || die "Could not find ESP. Expected /boot/efi (vfat). Mount it first."
  esp_details "$esp"
  # fstype check
  local fstype
  fstype="$(findmnt -n -o FSTYPE --target "$esp" 2>/dev/null || echo ?)"
  [[ "$fstype" == "vfat" ]] || warn "ESP fstype is '$fstype' (expected vfat). Continuing, but Limine needs FAT."
  ok "ESP found at $esp"

  echo "--- Space ---"
  local free need
  free="$(esp_free_mb "$esp")"
  need="$(needed_mb_estimate)"
  echo "ESP free: ${free}MB   estimated need (all kernels + 60MB headroom): ${need}MB"
  if [[ "$free" -lt "$need" ]]; then
    warn "ESP may be too small. Fix: sudo dnf remove --oldinstallonly (keep 2 kernels),"
    warn "or set installonly_limit=2 in /etc/dnf/dnf.conf, or enlarge the ESP."
    if ! confirm "Continue despite tight ESP space?"; then
      die "Aborted. Free ESP space and re-run."
    fi
  else
    ok "ESP space looks fine."
  fi

  echo "--- Kernels ---"
  local k
  k="$(list_fedora_kernels)"
  [[ -n "$k" ]] || die "No /boot/vmlinuz-* kernels found. Is this a Fedora install?"
  echo "$k" | while read -r v; do echo "  - $v"; done
  echo "cmdline: $(kernel_cmdline)"
  echo "root hint: $(root_hint)"

  echo "--- Bootloader state ---"
  efibootmgr -v 2>/dev/null | head -n 30 || warn "efibootmgr output unavailable."
  rpm -q grub2-efi-x64 grub2-common shim-x64 grubby 2>/dev/null || true
  if [[ -d /boot/grub2 || -d /boot/efi/EFI/fedora ]]; then
    ok "GRUB/Shim install detected (will be KEPT as fallback)."
  fi

  echo "--- Extras auto-detect ---"
  local rootfs
  rootfs="$(findmnt -n -o FSTYPE / 2>/dev/null || echo ?)"
  echo "Root fs: $rootfs"
  if [[ "$rootfs" == "btrfs" ]]; then
    echo "  -> BTRFS detected: snapshot boot entries are available (optional)."
  else
    echo "  -> Not BTRFS (this machine: $rootfs): snapshot entries will be skipped."
  fi
  command -v os-prober >/dev/null 2>&1 && echo "  -> os-prober present" || echo "  -> os-prober not installed (Windows scan optional)"
  [[ -d /boot/efi/EFI/Microsoft ]] && echo "  -> Windows ESP dir detected" || echo "  -> No Windows ESP dir seen"

  nvidia_preflight_report || true

  echo
  # Export for later steps
  ESP="$esp"
}

# ---------------------------------------------------------------- deps -----

install_deps() {
  log "Installing dependencies via dnf..."
  local pkgs=(efibootmgr dosfstools mtools curl tar gzip xz gawk coreutils grep sed
             binutils mokutil parted btrfs-progs)
  # gcc/make/nasm only needed for `limine bios-install` tool build from binary tarball.
  # The binary tarball ships limine.c + Makefile; `make` needs a C compiler.
  pkgs+=(gcc make)
  # Optional-but-nice (failures tolerated; correct Fedora package names!):
  #   memtest86+ -> /usr/lib64/memtest86+/memtest86+x64.efi
  #   edk2-shell-x64 -> /usr/share/edk2/ovmf/Shell.efi
  local opt_pkgs=(os-prober sbsigntools openssl memtest86+ edk2-shell-x64 snapper python3)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  (dry-run) dnf install -y ${pkgs[*]} ${opt_pkgs[*]}"
    return 0
  fi
  run dnf install -y "${pkgs[@]}" || die "dnf install of required deps failed."
  run dnf install -y "${opt_pkgs[@]}" || warn "Some optional packages failed (ok to ignore: ${opt_pkgs[*]})."
  ok "Dependencies installed."
}

# ---------------------------------------------------------------- limine fetch + deploy

fetch_limine() {
  local ver="$1" work="$2"
  local url="${LIMINE_BINARY_URL_TMPL//__VER__/$ver}"
  log "Downloading Limine v$ver binary release..."
  echo "  URL: $url"
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) curl -> $work/limine-binary.tar.xz"; return 0; fi
  mkdir -p "$work"
  curl -fSL --retry 3 -o "$work/limine-binary.tar.xz" "$url" || die "Download failed: $url"
  tar -tf "$work/limine-binary.tar.xz" | head -n 20
  mkdir -p "$work/extract"
  tar -xf "$work/limine-binary.tar.xz" -C "$work/extract"
  # Binary tarball nests under limine-binary/
  if [[ -f "$work/extract/limine-binary/BOOTX64.EFI" ]]; then
    LIMINE_SRC="$work/extract/limine-binary"
  else
    LIMINE_SRC="$(dirname "$(find "$work/extract" -name 'BOOTX64.EFI' | head -n1)")"
  fi
  [[ -n "${LIMINE_SRC:-}" && -f "$LIMINE_SRC/BOOTX64.EFI" ]] || die "BOOTX64.EFI not found in tarball."
  ok "Limine v$ver unpacked: $LIMINE_SRC"
  # Build the `limine` host tool (needed for bios-install + enroll-config).
  if command -v gcc >/dev/null 2>&1 && [[ -f "$LIMINE_SRC/Makefile" ]]; then
    log "Building 'limine' host tool..."
    (cd "$LIMINE_SRC" && run make) || warn "'make' in limine dir failed (UEFI-only install still works)."
  fi
}

deploy_uefi() {
  local esp="$1" src="$2"
  local dest_dir="$esp/EFI/limine" fallback="$esp/EFI/BOOT/BOOTX64.EFI"
  log "Deploying Limine UEFI binaries..."
  echo "  $src/BOOTX64.EFI -> $dest_dir/limine_x64.efi"
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) mkdir + cp + fallback"; return 0; fi
  mkdir -p "$dest_dir"
  cp -v "$src/BOOTX64.EFI" "$dest_dir/limine_x64.efi"
  # Keep a copy of the version for the hook's downgrade guard.
  cp -v "$src/BOOTX64.EFI" "$dest_dir/limine_x64.efi.versioned" 2>/dev/null || true
  echo "$LIMINE_VER" > "$dest_dir/.limine-version" 2>/dev/null || true
  # Fallback path (helps when NVRAM is wiped / "UEFI OS" entry). Back up existing first.
  if [[ "$DO_FALLBACK" -eq 1 ]]; then
    mkdir -p "$(dirname "$fallback")"
    if [[ -f "$fallback" ]]; then
      cp -v "$fallback" "$fallback.limine-bak-$(date +%F-%H%M%S)" || true
      warn "Existing $fallback backed up (was probably shim copy)."
    fi
    cp -v "$src/BOOTX64.EFI" "$fallback"
  fi
  command -v restorecon >/dev/null 2>&1 && restorecon -R "$esp/EFI/limine" 2>/dev/null || true
  ok "UEFI binaries deployed."
}

deploy_bios() {
  local src="$1"
  # Only runs when user explicitly opts in AND firmware is BIOS or hybrid.
  log "Deploying Limine BIOS files..."
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) cp limine-bios.sys + limine bios-install"; return 0; fi
  local limine_bin="$src/limine"
  [[ -x "$limine_bin" ]] || die "Host 'limine' tool not built ($limine_bin). Run make in the unpacked dir."
  mkdir -p /boot/limine
  cp -v "$src/limine-bios.sys" /boot/limine/
  local disk
  disk="$(ask_with_default "BIOS target DISK (whole disk, e.g. /dev/nvme0n1)" "$ESP_DISK")"
  [[ -b "$disk" ]] || die "Not a block device: $disk"
  warn "About to run: limine bios-install $disk  (writes MBR / GPT BIOS-boot stage)"
  confirm "Write Limine BIOS stage to $disk?" || die "BIOS install aborted."
  "$limine_bin" bios-install "$disk" || die "limine bios-install failed."
  ok "BIOS stage installed on $disk."
}

# ---------------------------------------------------------------- config ----

write_default_config() {
  log "Writing $CONFIG_FILE (CachyOS-style knobs, Fedora defaults)..."
  if [[ -f "$CONFIG_FILE" && "$ASSUME_YES" -eq 0 && "$MODE" == "install" ]]; then
    warn "$CONFIG_FILE already exists — keeping it (delete to regenerate defaults)."
    return 0
  fi
  local cmdline root osname timeout fb eb db ss sbm enroll verify
  cmdline="$(kernel_cmdline)"
  root="$(root_hint)"
  # Ensure root= is present exactly once.
  if [[ "$cmdline" != *"root="* ]]; then cmdline="$root $cmdline"; fi
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  osname="${PRETTY_NAME:-Fedora Linux}"
  timeout="$(ask_with_default "Boot menu timeout (seconds)" "5")"
  # DO_* are 0/1 ints (DO_SNAPSHOTS is "auto"/"no" here); config wants yes/no.
  fb="no"; [[ "${DO_FALLBACK:-0}" -eq 1 ]] && fb="yes"
  eb="no"; [[ "${DO_EFIBOOTMGR:-0}" -eq 1 ]] && eb="yes"
  db="no"; [[ "${DO_DUALBOOT_SCAN:-0}" -eq 1 ]] && db="yes"
  ss="$DO_SNAPSHOTS"  # already "auto" or "no"
  [[ "$ss" != "auto" && "$ss" != "yes" && "$ss" != "no" ]] && ss="no"
  sbm="${DO_SECUREBOOT:-no}"
  [[ "$sbm" != "mok-shim" && "$sbm" != "custom-db" ]] && sbm="no"
  enroll="no"; verify="no"
  if [[ "$sbm" != "no" ]]; then enroll="yes"; verify="yes"; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) write $CONFIG_FILE"; return 0; fi
  cat > "$CONFIG_FILE" <<EOF
# Fedora Limine settings — edit then run: sudo limine-update
# This mirrors CachyOS /etc/default/limine knobs, translated for Fedora/dracut.

# Where the ESP is mounted.
ESP_PATH="$ESP"

# Subdir layout on ESP: \$ESP/<machine-id>/<kernel-version>/
# (CachyOS-compatible; FAT-safe, survives kernel updates via kernel-install hook.)
MACHINE_ID="$(machine_id)"

# Menu behaviour.
TIMEOUT="$timeout"
DEFAULT_ENTRY="1"
REMEMBER_LAST="yes"

# Cosmetics (Catppuccin Mocha, same as CachyOS default).
TERM_PALETTE="1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4"
TERM_PALETTE_BRIGHT="585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4"
TERM_BACKGROUND="ffffffff"
TERM_FOREGROUND="cdd6f4"
# Optional splash (copied to ESP if the file exists):
# WALLPAPER="/boot/limine-splash.png"

# OS display name at top of menu.
TARGET_OS_NAME="$osname"

# Kernel cmdline for normal boots. rescue/fallback entries append 'single nomodeset' style flags below.
KERNEL_CMDLINE="$cmdline"

# Boot order glob for generated entries: normal kernels first, then fallback/rescue, then snapshots.
BOOT_ORDER="*, *fallback, *rescue, Snapshots"

# Deploy fallback EFI/BOOT/BOOTX64.EFI copy? (yes = survives NVRAM wipes)
ENABLE_FALLBACK="$fb"

# Register an efibootmgr NVRAM entry? (yes on real hardware, no in containers/VMs without efivars)
ENABLE_EFIBOOTMGR="$eb"

# Scan ESP for Windows / other EFI loaders and add chainload entries? (like CachyOS FIND_BOOTLOADERS=yes)
FIND_BOOTLOADERS="$db"

# Snapshot boot entries (BTRFS + snapper only; auto-skipped otherwise).
ENABLE_SNAPSHOTS="$ss"
MAX_SNAPSHOT_ENTRIES="10"

# Secure Boot (opt-in). no | mok-shim (MOK + shim chainload, recommended)
# | custom-db (firmware db enrollment in Setup Mode, advanced).
SECURE_BOOT="$sbm"
SB_KEY_DIR="$SB_KEY_DIR"
SB_KEY_CN="Fedora Limine Secure Boot"

# Append BLAKE2b hashes to linux paths (kernel/initramfs/wallpaper).
# Forced yes when SECURE_BOOT != no (Limine panics on hashless paths under SB
# once a conf hash is enrolled). Harmless when SB is off (defense in depth).
ENABLE_VERIFICATION="$verify"

# Bake b2sum(limine.conf) into the EFI binaries via `limine enroll-config`
# (explicit opt-in to SB hardening; re-enrolled + re-signed on every sync).
ENABLE_ENROLL_CONFIG="$enroll"
EOF
  ok "$CONFIG_FILE written. Edit KERNEL_CMDLINE/TIMEOUT there anytime, then: sudo limine-update"
}

# ---------------------------------------------------------------- hook + sync

install_hook_and_sync_script() {
  log "Installing kernel-install hook + sync generator (Fedora equivalent of CachyOS pacman hooks)..."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  (dry-run) write $SYNC_SCRIPT, $UPDATE_WRAPPER, $HOOK_FILE"
    return 0
  fi

  # ---- generator -----------------------------------------------------------
  cat > "$SYNC_SCRIPT" <<'SYNC_EOF'
#!/usr/bin/env bash
# limine-fedora-sync — copy Fedora kernels to the FAT ESP + regenerate limine.conf
# Called by /etc/kernel/install.d/95-limine.install on every kernel add/remove,
# and manually by `limine-update`. CachyOS equivalent: limine-mkinitcpio / limine-dracut
# + limine-entry-tool --add-kernel.
# Secure Boot: when ENABLE_VERIFICATION=yes (forced when SECURE_BOOT != no),
# linux paths get #<b2sum> suffixes; when ENABLE_ENROLL_CONFIG=yes the conf
# hash is re-enrolled into managed EFIs and they are re-signed (sb_post_process).
#
# Layout (CachyOS-style): $ESP/<machine-id>/<version>/{vmlinuz-*,initramfs-*.img}
# Config search path covered: $ESP/limine.conf + $ESP/EFI/limine/limine.conf + $ESP/EFI/BOOT/limine.conf
set -euo pipefail
CONFIG="/etc/default/limine"
# Defaults if config missing:
ESP_PATH="${ESP_PATH:-/boot/efi}"
MACHINE_ID="$(cat /etc/machine-id 2>/dev/null | tr -d ' \n')"
TIMEOUT="5"; DEFAULT_ENTRY="1"; REMEMBER_LAST="yes"
TERM_PALETTE="1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4"
TERM_PALETTE_BRIGHT="585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4"
TERM_BACKGROUND="ffffffff"; TERM_FOREGROUND="cdd6f4"; WALLPAPER=""
TARGET_OS_NAME="Fedora Linux"; KERNEL_CMDLINE=""; BOOT_ORDER="*, *fallback, *rescue, Snapshots"
FIND_BOOTLOADERS="yes"; ENABLE_SNAPSHOTS="auto"; MAX_SNAPSHOT_ENTRIES="10"
SECURE_BOOT="no"; SB_KEY_DIR="/etc/limine/keys"
ENABLE_VERIFICATION="no"; ENABLE_ENROLL_CONFIG="no"; ENABLE_FALLBACK="yes"
LIMINE_TOOL="/usr/local/bin/limine"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && . "$CONFIG"
[[ -n "${MACHINE_ID_OVERRIDE:-}" ]] && MACHINE_ID="$MACHINE_ID_OVERRIDE"
[[ -n "${MACHINE_ID:-}" ]] || MACHINE_ID="$(cat /etc/machine-id | tr -d ' \n')"
ESP="${ESP_PATH}"
[[ -d "$ESP" ]] || { echo "limine-fedora-sync: ESP not found: $ESP" >&2; exit 1; }

KERNEL_DIR_BASE="$ESP/$MACHINE_ID"
mkdir -p "$KERNEL_DIR_BASE"

sync_one() {
  local ver="$1"
  local src_vmlinuz="/boot/vmlinuz-$ver" src_initrd="/boot/initramfs-$ver.img"
  [[ -f "$src_vmlinuz" ]] || { echo "  skip $ver (no $src_vmlinuz)"; return 0; }
  local dest="$KERNEL_DIR_BASE/$ver"
  mkdir -p "$dest"
  echo "  sync $ver -> $dest"
  cp -v --preserve=timestamps "$src_vmlinuz" "$dest/vmlinuz-$ver"
  if [[ -f "$src_initrd" ]]; then
    cp -v --preserve=timestamps "$src_initrd" "$dest/initramfs-$ver.img"
  else
    echo "  WARN: no initramfs for $ver ($src_initrd missing)" >&2
  fi
  # Fedora embeds early microcode INSIDE initramfs (dracut early_microcode=yes),
  # so no separate ucode file is needed (unlike Arch's /boot/*-ucode.img).
  command -v restorecon >/dev/null 2>&1 && restorecon -R "$dest" 2>/dev/null || true
}

prune_stale() {
  # Remove ESP dirs for kernels no longer in /boot.
  local d ver
  for d in "$KERNEL_DIR_BASE"/*/; do
    [[ -d "$d" ]] || continue
    ver="$(basename "$d")"
    if [[ ! -f "/boot/vmlinuz-$ver" && "$ver" != "rescue" ]]; then
      echo "  prune stale ESP entry: $ver"
      rm -rf "$d"
    fi
  done
}

sb_post_process() {
  # Secure Boot: re-enroll conf hash + re-sign managed EFIs after every regen.
  # Never fails the caller (kernel-install hook must not break): warn + continue.
  [[ "${ENABLE_ENROLL_CONFIG:-no}" == "yes" ]] || return 0
  local tool="${LIMINE_TOOL:-/usr/local/bin/limine}"
  command -v "$tool" >/dev/null 2>&1 || tool="$(command -v limine 2>/dev/null || true)"
  [[ -n "${tool:-}" ]] || { echo "  SB: limine tool missing, skipping enroll/sign" >&2; return 0; }
  local keydir="${SB_KEY_DIR:-/etc/limine/keys}"
  if [[ ! -f "$keydir/MOK.priv" || ! -f "$keydir/MOK.pem" ]]; then
    echo "  SB: keys missing in $keydir, skipping enroll/sign (run limine --sb-setup)" >&2
    return 0
  fi
  command -v sbsign >/dev/null 2>&1 || { echo "  SB: sbsign missing, skipping sign" >&2; return 0; }
  local hash e tmp
  hash="$(b2sum "$ESP/limine.conf" | cut -d' ' -f1)"
  local efis=()
  efis+=("$ESP/EFI/limine/limine_x64.efi")
  [[ "${ENABLE_FALLBACK:-yes}" == "yes" ]] && efis+=("$ESP/EFI/BOOT/BOOTX64.EFI")
  if [[ "${SECURE_BOOT:-no}" == "mok-shim" && -f "$ESP/EFI/fedora/grubx64.efi.grub-bak" && -f "$ESP/EFI/fedora/grubx64.efi" ]]; then
    efis+=("$ESP/EFI/fedora/grubx64.efi")
  fi
  for e in "${efis[@]}"; do
    [[ -f "$e" ]] || continue
    "$tool" enroll-config "$e" "$hash" >/dev/null 2>&1 || { echo "  SB: enroll failed for $e" >&2; continue; }
    tmp="$(mktemp /tmp/limine-sign-XXXXXX.efi)"
    if sbsign --key "$keydir/MOK.priv" --cert "$keydir/MOK.pem" --output "$tmp" "$e" >/dev/null 2>&1; then
      mv "$tmp" "$e"
    else
      rm -f "$tmp"; echo "  SB: sbsign failed for $e" >&2
    fi
  done
  command -v restorecon >/dev/null 2>&1 && restorecon -R "$ESP/EFI" 2>/dev/null || true
}

gen_conf() {
  local tmp="$ESP/limine.conf.tmp"
  local wallpaper_line=""
  local VERIFY_ON="no"
  [[ "${ENABLE_VERIFICATION:-no}" == "yes" || "${SECURE_BOOT:-no}" != "no" ]] && VERIFY_ON="yes"
  if [[ -n "${WALLPAPER:-}" && -f "${WALLPAPER:-}" ]]; then
    cp -v "$WALLPAPER" "$ESP/limine-splash.png" 2>/dev/null || true
    if [[ "$VERIFY_ON" == "yes" && -f "$ESP/limine-splash.png" ]]; then
      wallpaper_line="wallpaper: boot():/limine-splash.png#$(b2sum "$ESP/limine-splash.png" | cut -d' ' -f1)"
    else
      wallpaper_line="wallpaper: boot():/limine-splash.png"
    fi
  fi
  {
    echo "# Generated by limine-fedora-sync on $(date -u +%FT%TZ). DO NOT EDIT — edit $CONFIG then run limine-update."
    echo "timeout: ${TIMEOUT}"
    echo "default_entry: ${DEFAULT_ENTRY}"
    echo "remember_last_entry: ${REMEMBER_LAST}"
    echo "term_palette: ${TERM_PALETTE}"
    echo "term_palette_bright: ${TERM_PALETTE_BRIGHT}"
    echo "term_background: ${TERM_BACKGROUND}"
    echo "term_foreground: ${TERM_FOREGROUND}"
    [[ -n "$wallpaper_line" ]] && echo "$wallpaper_line"
    echo ""
    echo "/${TARGET_OS_NAME}"
    # Normal kernels, newest first.
    local vers v printed=0
    vers="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v '^0-rescue' | sort -Vr || true)"
    for v in $vers; do
      [[ -f "$KERNEL_DIR_BASE/$v/vmlinuz-$v" ]] || continue
      printed=$((printed+1))
      # BLAKE2b suffixes when verification is on (mandatory under SB+enroll).
      local kfile="$KERNEL_DIR_BASE/$v/vmlinuz-$v" ifile="$KERNEL_DIR_BASE/$v/initramfs-$v.img"
      local ksuffix="" isuffix=""
      if [[ "$VERIFY_ON" == "yes" ]]; then
        ksuffix="#$(b2sum "$kfile" | cut -d' ' -f1)"
        [[ -f "$ifile" ]] && isuffix="#$(b2sum "$ifile" | cut -d' ' -f1)"
      fi
      echo "    //${v}"
      echo "    comment: Fedora kernel $v (auto-generated)"
      echo "    protocol: linux"
      echo "    path: boot():/${MACHINE_ID}/${v}/vmlinuz-${v}${ksuffix}"
      # KERNEL_CMDLINE already contains root=... ; fall back to /proc/cmdline if empty.
      local cmd="$KERNEL_CMDLINE"
      [[ -z "$cmd" ]] && cmd="$(tr ' ' '\n' < /proc/cmdline | grep -v '^BOOT_IMAGE=' | tr '\n' ' ')"
      echo "    cmdline: ${cmd}"
      if [[ -f "$KERNEL_DIR_BASE/$v/initramfs-$v.img" ]]; then
        echo "    module_path: boot():/${MACHINE_ID}/${v}/initramfs-${v}.img${isuffix}"
      fi
      echo ""
    done
    [[ "$printed" -gt 0 ]] || echo "    //no-kernels-found (run: kernel-install add-all)"
    # Rescue entry (Fedora dracut rescue image).
    local rvmlinuz rinitrd
    rvmlinuz="$(ls -1 /boot/vmlinuz-0-rescue* 2>/dev/null | head -n1 || true)"
    rinitrd="$(ls -1 /boot/initramfs-0-rescue*.img 2>/dev/null | head -n1 || true)"
    if [[ -n "$rvmlinuz" && -f "$rvmlinuz" ]]; then
      mkdir -p "$KERNEL_DIR_BASE/rescue"
      cp -n --preserve=timestamps "$rvmlinuz" "$KERNEL_DIR_BASE/rescue/$(basename "$rvmlinuz")" 2>/dev/null || true
      [[ -n "$rinitrd" && -f "$rinitrd" ]] && cp -n --preserve=timestamps "$rinitrd" "$KERNEL_DIR_BASE/rescue/$(basename "$rinitrd")" 2>/dev/null || true
      local rb vb
      rb="$(basename "$rvmlinuz")"; vb="$rb"
      local rksuffix="" risuffix=""
      if [[ "$VERIFY_ON" == "yes" ]]; then
        [[ -f "$KERNEL_DIR_BASE/rescue/$rb" ]] && rksuffix="#$(b2sum "$KERNEL_DIR_BASE/rescue/$rb" | cut -d' ' -f1)"
        if [[ -n "$rinitrd" && -f "$KERNEL_DIR_BASE/rescue/$(basename "$rinitrd")" ]]; then
          risuffix="#$(b2sum "$KERNEL_DIR_BASE/rescue/$(basename "$rinitrd")" | cut -d' ' -f1)"
        fi
      fi
      echo "    //rescue"
      echo "    comment: Fedora rescue (auto-generated)"
      echo "    protocol: linux"
      echo "    path: boot():/${MACHINE_ID}/rescue/${rb}${rksuffix}"
      local cmd="$KERNEL_CMDLINE"
      [[ -z "$cmd" ]] && cmd="$(tr ' ' '\n' < /proc/cmdline | grep -v '^BOOT_IMAGE=' | tr '\n' ' ')"
      echo "    cmdline: ${cmd} single nomodeset"
      if [[ -n "$rinitrd" && -f "$KERNEL_DIR_BASE/rescue/$(basename "$rinitrd")" ]]; then
        echo "    module_path: boot():/${MACHINE_ID}/rescue/$(basename "$rinitrd")${risuffix}"
      fi
      echo ""
    fi
    # Snapshot placeholder (filled by snapper helper if enabled; harmless if empty).
    if [[ "$ENABLE_SNAPSHOTS" == "yes" || "$ENABLE_SNAPSHOTS" == "auto" ]]; then
      if [[ -f "$ESP/limine-snapshots.conf" ]]; then
        echo "    //Snapshots"
        cat "$ESP/limine-snapshots.conf"
        echo ""
      fi
    fi
    # Dual-boot scan: Windows + other EFI loaders on the ESP.
    if [[ "$FIND_BOOTLOADERS" == "yes" ]]; then
      if [[ -f "$ESP/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        echo "/Windows Boot Manager"
        echo "    protocol: efi"
        echo "    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi"
        echo ""
      fi
      # memtest86+ (Fedora package drops it at /boot/efi/EFI/memtest86+/... or /boot/memtest*)
      local mem=""
      for mem in "$ESP/EFI/memtest86+/memtest86x64.efi" "$ESP/memtest86+/memtest86x64.efi"; do
        if [[ -f "$mem" ]]; then
          local rel="${mem#$ESP/}"
          echo "/Memtest86+"
          echo "    protocol: efi"
          echo "    path: boot():/${rel}"
          echo ""
          break
        fi
      done
      # EDK2 shell if present.
      if [[ -f "$ESP/EFI/tools/Shell.efi" || -f "$ESP/shellx64.efi" ]]; then
        local sh="EFI/tools/Shell.efi"
        [[ -f "$ESP/shellx64.efi" ]] && sh="shellx64.efi"
        echo "/EDK2 Shell"
        echo "    protocol: efi"
        echo "    path: boot():/${sh}"
        echo ""
      fi
    fi
  } > "$tmp"
  # Atomic publish to all locations Limine searches (vfat has no symlinks -> copy).
  cp -v "$tmp" "$ESP/limine.conf"
  mkdir -p "$ESP/EFI/limine" "$ESP/EFI/BOOT" "$ESP/boot/limine" 2>/dev/null || true
  cp -v "$tmp" "$ESP/EFI/limine/limine.conf"
  cp -v "$tmp" "$ESP/EFI/BOOT/limine.conf"
  rm -f "$tmp"
  sb_post_process
  echo "limine.conf regenerated ($(grep -c '^    //\|^/' "$ESP/limine.conf") entries)."
}

case "${1:-sync}" in
  sync|add|resync|regenerate)
    if [[ "${2:-}" != "" && "${2:-}" != "all" ]]; then
      sync_one "$2"   # single-version fast path from kernel-install hook
    else
      for v in $(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v '^0-rescue' | sort -Vr); do
        sync_one "$v"
      done
      prune_stale
    fi
    gen_conf
    ;;
  remove)
    ver="${2:-}"; [[ -n "$ver" ]] && rm -rf "$KERNEL_DIR_BASE/$ver"
    gen_conf
    ;;
  conf-only|config)
    gen_conf
    ;;
  *)
    echo "Usage: $0 [sync [VERSION|all]|remove VERSION|conf-only]"; exit 2 ;;
esac
SYNC_EOF
  chmod +x "$SYNC_SCRIPT"

  # ---- limine-update wrapper (CachyOS parity) --------------------------------
  cat > "$UPDATE_WRAPPER" <<'UPD_EOF'
#!/usr/bin/env bash
# limine-update — re-sync kernels + regenerate limine.conf (CachyOS parity wrapper).
set -euo pipefail
exec /usr/local/sbin/limine-fedora-sync sync all
UPD_EOF
  chmod +x "$UPDATE_WRAPPER"

  # ---- kernel-install hook ----------------------------------------------------
  cat > "$HOOK_FILE" <<'HOOK_EOF'
#!/usr/bin/bash
# 95-limine.install — Fedora kernel-install plugin for Limine.
# Runs after 50-dracut (so initramfs exists) on every kernel add/remove.
# Mirrors CachyOS 90-mkinitcpio-install.hook / 90-limine-dracut-install.hook.
COMMAND="${1:?}"
KERNEL_VERSION="${2:?}"
# BOOT_DIR_ABS / KERNEL_IMAGE may be present but we sync from /boot directly.
if ! [[ ${KERNEL_INSTALL_MACHINE_ID-x} ]]; then exit 0; fi
case "$COMMAND" in
  add)
    # dracut (50-dracut.install) runs first (lexicographic 50 < 95), so
    # /boot/initramfs-<ver>.img already exists here on a normal install.
    /usr/local/sbin/limine-fedora-sync sync "$KERNEL_VERSION" || exit 0
    ;;
  remove)
    /usr/local/sbin/limine-fedora-sync remove "$KERNEL_VERSION" || exit 0
    ;;
  *) exit 0 ;;
esac
HOOK_EOF
  chmod +x "$HOOK_FILE"

  ok "Hook + sync scripts installed:"
  echo "  $HOOK_FILE"
  echo "  $SYNC_SCRIPT"
  echo "  $UPDATE_WRAPPER  (run this after editing $CONFIG_FILE)"
}

sync_all_kernels() {
  log "Syncing Fedora kernels to ESP + generating limine.conf..."
  run "$SYNC_SCRIPT" sync all
}

# ---------------------------------------------------------------- efibootmgr

register_efibootmgr() {
  local esp="$1"
  if [[ "$DO_EFIBOOTMGR" -eq 0 ]]; then
    warn "Skipping efibootmgr registration (per your choice / no efivars)."
    return 0
  fi
  local src esp_disk esp_part label loader pkname
  src="$(esp_source "$esp")"
  pkname="$(lsblk -n -o PKNAME "$src" 2>/dev/null | head -n1 || true)"
  esp_part="$(lsblk -n -o PARTN "$src" 2>/dev/null | head -n1 || true)"
  if [[ -z "${pkname:-}" ]]; then
    esp_disk=""
  else
    esp_disk="/dev/$pkname"
  fi
  label="Limine"
  loader='\EFI\limine\limine_x64.efi'
  if [[ -z "${esp_disk:-}" || -z "${esp_part:-}" ]]; then
    warn "Could not resolve ESP disk/part from $src — printing manual command:"
    echo "  efibootmgr -c -L \"$label\" -l '$loader'"
    return 0
  fi
  log "Registering NVRAM entry: $label on $esp_disk part $esp_part ($loader)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  (dry-run) efibootmgr -c -d $esp_disk -p $esp_part -L \"$label\" -l '$loader'"
    return 0
  fi
  # Avoid duplicates: delete existing "Limine" entries first.
  local dup
  dup="$(efibootmgr -v 2>/dev/null | grep -i 'limine' | grep -o 'Boot[0-9A-Fa-f]*' | grep -o '[0-9A-Fa-f]*' || true)"
  for d in $dup; do
    warn "Removing stale Limine NVRAM entry Boot$d"
    efibootmgr -b "$d" -B 2>/dev/null || true
  done
  efibootmgr -c -d "$esp_disk" -p "$esp_part" -L "$label" -l "$loader" || {
    warn "efibootmgr -c failed (common in VMs/containers without efivars). Limine files are still on the ESP;"
    warn "fallback EFI/BOOT/BOOTX64.EFI will be used if enabled."
    return 0
  }
  echo "--- Current boot entries ---"
  efibootmgr -v || true
  # Put Limine first, keep everything else (GRUB stays as fallback).
  local limine_num
  limine_num="$(efibootmgr 2>/dev/null | grep -i 'limine' | head -n1 | grep -o '[0-9A-Fa-f]\{4\}' | head -n1 || true)"
  if [[ -n "$limine_num" ]]; then
    local order rest
    order="$(efibootmgr 2>/dev/null | grep '^BootOrder:' | awk '{print $2}' || true)"
    # Build "limine,rest..." without duplicating.
    rest="$(echo "$order" | tr ',' '\n' | grep -vi "^$limine_num\$" | paste -sd, - || true)"
    if [[ -n "$rest" ]]; then
      log "Setting BootOrder: $limine_num,$rest (Limine first, GRUB kept as fallback)"
      efibootmgr -o "$limine_num,$rest" || warn "Could not set BootOrder (set it manually in firmware)."
    fi
  fi
  ok "NVRAM entry registered. Old 'Fedora' (GRUB/shim) entry kept for rollback."
}

# ------------------------------------------------------- secure boot -------

# Secure Boot support (opt-in). Upstream model (USAGE.md/FAQ.md):
#   sign Limine EFI + `limine enroll-config <efi> <b2sum-of-limine.conf>`.
# When SB is active AND a hash is enrolled, Limine enforces: config verified
# every boot, all linux paths MUST carry `#<hash>` (b2sum, 128 hex), editor
# disabled, hash_mismatch_panic forced yes. EFI chainloads (Windows/memtest/
# shell) are exempt (firmware verifies those).
# Two methods:
#   mok-shim   (recommended, idiot-proof): MOK key, sign Limine, enroll MOK
#              via MokManager (no firmware Setup Mode), deploy signed Limine
#              as EFI/fedora/grubx64.efi so Fedora's MS-signed shim loads it.
#              Direct EFI/limine entry also works once SB is off or db covers it.
#   custom-db  (advanced): same keypair enrolled into firmware `db` in Setup
#              Mode (efi-updatevar), direct firmware -> Limine boot, no shim.
# `--yes` never enrolls keys (MOK import needs a reboot + password).

sb_config_load() {
  # Load /etc/default/limine knobs with safe defaults. Sets globals:
  # SB_ESP, SB_MODE, SB_KEYS, SB_CN, SB_VERIFY, SB_ENROLL, SB_FALLBACK.
  SB_ESP="/boot/efi"; SB_MODE="no"; SB_KEYS="$SB_KEY_DIR_DEFAULT"
  SB_CN="Fedora Limine Secure Boot"; SB_VERIFY="no"; SB_ENROLL="no"; SB_FALLBACK="yes"
  # shellcheck disable=SC1090
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1091
    . "$CONFIG_FILE" || true
    [[ -n "${ESP_PATH:-}" ]] && SB_ESP="$ESP_PATH"
    [[ -n "${SECURE_BOOT:-}" ]] && SB_MODE="$SECURE_BOOT"
    [[ -n "${SB_KEY_DIR:-}" ]] && SB_KEYS="$SB_KEY_DIR"
    [[ -n "${SB_KEY_CN:-}" ]] && SB_CN="$SB_KEY_CN"
    [[ -n "${ENABLE_VERIFICATION:-}" ]] && SB_VERIFY="$ENABLE_VERIFICATION"
    [[ -n "${ENABLE_ENROLL_CONFIG:-}" ]] && SB_ENROLL="$ENABLE_ENROLL_CONFIG"
    [[ -n "${ENABLE_FALLBACK:-}" ]] && SB_FALLBACK="$ENABLE_FALLBACK"
  fi
}

sb_keys_present() {
  local dir="${1:-$SB_KEY_DIR_DEFAULT}"
  [[ -f "$dir/MOK.priv" && -f "$dir/MOK.pem" ]]
}

sb_managed_efis() {
  # Print managed Limine EFI paths (existing files only), one per line.
  # $1 = ESP. Uses SB_MODE/SB_FALLBACK globals (call sb_config_load first).
  local esp="$1" f
  f="$esp/EFI/limine/limine_x64.efi"
  [[ -f "$f" ]] && echo "$f"
  if [[ "${SB_FALLBACK:-yes}" == "yes" ]]; then
    f="$esp/EFI/BOOT/BOOTX64.EFI"
    [[ -f "$f" ]] && echo "$f"
  fi
  if [[ "${SB_MODE:-no}" == "mok-shim" ]]; then
    # Only the copy we placed (proven by our GRUB backup existing).
    if [[ -f "$esp/EFI/fedora/grubx64.efi.grub-bak" && -f "$esp/EFI/fedora/grubx64.efi" ]]; then
      echo "$esp/EFI/fedora/grubx64.efi"
    fi
  fi
}

sb_ensure_tools() {
  local method="${1:-mok-shim}"
  local need=(openssl mokutil sbsign sbverify b2sum)
  local missing=()
  local t
  for t in "${need[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ "${#missing[@]}" -eq 0 && "$method" != "custom-db" ]]; then return 0; fi
  if [[ "$method" == "custom-db" ]]; then
    command -v efi-readvar >/dev/null 2>&1 || missing+=("efitools(efi-readvar)")
  fi
  if [[ "${#missing[@]}" -eq 0 ]]; then return 0; fi
  log "Installing Secure Boot tools (missing: ${missing[*]})..."
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) dnf install -y sbsigntools openssl mokutil efitools"; return 0; fi
  run dnf install -y sbsigntools openssl mokutil || die "Failed to install SB tools."
  if [[ "$method" == "custom-db" ]]; then
    run dnf install -y efitools || warn "efitools install failed (needed for db enrollment checks)."
  fi
}

sb_keygen() {
  local dir="${1:-$SB_KEY_DIR_DEFAULT}" cn="${2:-$SB_CN}"
  if sb_keys_present "$dir"; then
    ok "SB keys already exist in $dir (keeping; delete to regenerate)."
    return 0
  fi
  log "Generating Secure Boot keypair in $dir (CN: $cn)..."
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) openssl req + x509 der"; return 0; fi
  run mkdir -p "$dir"
  run chmod 700 "$dir"
  run openssl req -new -x509 -newkey rsa:2048 -keyout "$dir/MOK.priv" -out "$dir/MOK.pem" \
    -days 36500 -nodes -subj "/CN=$cn/"
  run openssl x509 -in "$dir/MOK.pem" -outform der -out "$dir/MOK.der"
  run chmod 600 "$dir/MOK.priv"
  run chmod 644 "$dir/MOK.pem" "$dir/MOK.der"
  ok "Keys created: $dir/MOK.{priv,pem,der}"
}

sb_sign_file() {
  local efi="$1" dir="${2:-$SB_KEY_DIR_DEFAULT}"
  [[ -f "$efi" ]] || { warn "sign: missing $efi (skipping)"; return 0; }
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) sbsign $efi + sbverify"; return 0; fi
  command -v sbsign >/dev/null 2>&1 || { warn "sbsign missing (skipping $efi)"; return 0; }
  local tmp
  tmp="$(mktemp /tmp/limine-sign-XXXXXX.efi)"
  # NOTE: enroll-config (if any) must run BEFORE this: signing seals the binary.
  run sbsign --key "$dir/MOK.priv" --cert "$dir/MOK.pem" --output "$tmp" "$efi" \
    || { rm -f "$tmp"; die "sbsign failed for $efi"; }
  run mv "$tmp" "$efi"
  if command -v sbverify >/dev/null 2>&1; then
    run sbverify --cert "$dir/MOK.pem" "$efi" || warn "sbverify failed for $efi"
  fi
  command -v restorecon >/dev/null 2>&1 && restorecon "$efi" 2>/dev/null || true
}

sb_enroll_and_sign() {
  # Re-enroll current limine.conf hash into all managed EFIs, then re-sign.
  # MUST run after limine.conf is final (sync first). $1 = ESP.
  local esp="$1" dir="${2:-$SB_KEY_DIR_DEFAULT}"
  local tool="${LIMINE_TOOL}"
  command -v "$tool" >/dev/null 2>&1 || tool="$(command -v limine || true)"
  if [[ -z "${tool:-}" ]]; then
    warn "limine host tool missing ($LIMINE_TOOL) — cannot enroll-config. Reinstall Limine first."
    return 0
  fi
  if ! sb_keys_present "$dir"; then
    warn "SB keys missing in $dir — cannot sign. Run: sudo $0 --sb-setup"
    return 0
  fi
  [[ -f "$esp/limine.conf" ]] || { warn "no $esp/limine.conf (run limine-update first)"; return 0; }
  local hash efi n=0
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) b2sum conf -> enroll-config + sbsign each managed EFI"; return 0; fi
  hash="$(b2sum "$esp/limine.conf" | cut -d' ' -f1)"
  [[ "${#hash}" -eq 128 ]] || die "unexpected b2sum length (${#hash})"
  while IFS= read -r efi; do
    [[ -n "$efi" ]] || continue
    log "Enrolling conf hash into $efi ..."
    run "$tool" enroll-config "$efi" "$hash" || warn "enroll-config failed for $efi"
    sb_sign_file "$efi" "$dir"
    n=$((n + 1))
  done < <(sb_managed_efis "$esp")
  [[ "$n" -gt 0 ]] || warn "No managed EFIs found under $esp (is Limine deployed?)"
  ok "Enrolled + signed $n EFI(s)."
}

sb_set_config() {
  # Idempotently set SECURE_BOOT / ENABLE_VERIFICATION / ENABLE_ENROLL_CONFIG.
  local method="$1"
  [[ -f "$CONFIG_FILE" ]] || die "No $CONFIG_FILE (run install first)."
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) set SECURE_BOOT=$method + verification/enroll yes in $CONFIG_FILE"; return 0; fi
  cp -a "$CONFIG_FILE" "$CONFIG_FILE.sb-bak-$(date +%F-%H%M%S)"
  local k
  for k in SECURE_BOOT ENABLE_VERIFICATION ENABLE_ENROLL_CONFIG SB_KEY_DIR; do
    if grep -q "^$k=" "$CONFIG_FILE"; then
      case "$k" in
        SECURE_BOOT) run sed -i "s|^$k=.*|$k=\"$method\"|" "$CONFIG_FILE" ;;
        SB_KEY_DIR) run sed -i "s|^$k=.*|$k=\"${SB_KEYS:-$SB_KEY_DIR_DEFAULT}\"|" "$CONFIG_FILE" ;;
        *) run sed -i "s|^$k=.*|$k=\"yes\"|" "$CONFIG_FILE" ;;
      esac
    else
      case "$k" in
        SECURE_BOOT) echo "$k=\"$method\"" >> "$CONFIG_FILE" ;;
        SB_KEY_DIR) echo "$k=\"${SB_KEYS:-$SB_KEY_DIR_DEFAULT}\"" >> "$CONFIG_FILE" ;;
        *) echo "$k=\"yes\"" >> "$CONFIG_FILE" ;;
      esac
    fi
  done
  ok "Config updated: SECURE_BOOT=$method, verification+enroll enabled."
}

sb_deploy_shim_copy() {
  # mok-shim method: backup real GRUB, place SIGNED Limine as grubx64.efi
  # so MS-signed shim loads our MOK-signed Limine. $1 = ESP.
  local esp="$1"
  local grub="$esp/EFI/fedora/grubx64.efi" bak="$esp/EFI/fedora/grubx64.efi.grub-bak"
  local src="$esp/EFI/limine/limine_x64.efi"
  [[ -f "$src" ]] || die "No $src (deploy Limine first)."
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) backup $grub -> .grub-bak; copy signed $src -> $grub"; return 0; fi
  if [[ -f "$bak" ]]; then
    ok "GRUB backup already exists: $bak (leaving it)."
  elif [[ -f "$grub" ]]; then
    run cp -v "$grub" "$bak" || die "Could not back up $grub"
  else
    warn "No $grub to back up (GRUB not installed here?) — placing Limine anyway."
  fi
  run cp -v "$src" "$grub" || die "Could not place shim copy."
  ok "Shim-chain copy placed: $grub (signed Limine; original GRUB in .grub-bak)."
}

sb_restore_shim() {
  # Restore real GRUB after mok-shim. $1 = ESP.
  local esp="$1"
  local grub="$esp/EFI/fedora/grubx64.efi" bak="$esp/EFI/fedora/grubx64.efi.grub-bak"
  if [[ ! -f "$bak" ]]; then
    warn "No GRUB backup at $bak (nothing to restore)."
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) restore $bak -> $grub"; return 0; fi
  run cp -v "$bak" "$grub"
  ok "GRUB restored from backup. (Removing $bak? Keeping it is safer — delete manually.)"
}

sb_print_mok_instructions() {
  local dir="${1:-$SB_KEY_DIR_DEFAULT}"
  cat <<EOF

${C_BLD}MOK enrollment — one reboot required:${C_RST}
  1. On the next boot, the blue MokManager screen appears.
     Choose: Enroll MOK -> Continue -> Yes -> enter the password you just set
     -> Reboot.
  2. If you missed it: re-run  sudo mokutil --import $dir/MOK.der
  3. Verify after reboot:  mokutil --list-enrolled | grep -i limine
                           sbverify --cert $dir/MOK.pem /boot/efi/EFI/limine/limine_x64.efi
  Boot path with SB on: firmware -> shimx64.efi (MS-signed) -> grubx64.efi
  ( = signed Limine, MOK-verified) -> Fedora kernels (hash-verified by Limine).
  Direct 'Limine' NVRAM entry boots only with SB off (or custom-db enrolled).
EOF
}

sb_print_db_guide() {
  local dir="${1:-$SB_KEY_DIR_DEFAULT}"
  cat <<EOF

${C_BLD}custom-db method — firmware Setup Mode required (advanced):${C_RST}
  Your key ($dir/MOK.pem) must join the firmware signature database.
  1. Reboot into firmware setup. Find Secure Boot options and either:
       - enable 'Setup Mode' / 'Clear Secure Boot Keys', or
       - use 'Enroll EFI image / Enroll signature' to add MOK.der/MOK.pem.
     (Menus differ per vendor: ASUS 'Key Management', Lenovo 'Certificates',
      Dell 'Expert Key Management'. Setup Mode shows as:
       mokutil --sb-state -> 'SecureBoot disabled' + efi-readvar shows no PK.)
  2. In Setup Mode, enroll (from Fedora):
       sudo cert-to-efi-sig-list -g "$(cat /etc/machine-id)" $dir/MOK.pem $dir/MOK.esl
       sudo efi-updatevar -e -f $dir/MOK.esl db
       sudo efi-readvar   # confirm your cert in db, then re-enable SB (Deploy Mode)
     (efitools provides cert-to-efi-sig-list, efi-updatevar, efi-readvar.)
  3. Then re-run:  sudo $0 --sb-resign
     Direct 'Limine' NVRAM entry then verifies against firmware db — no shim.
  Keep a Fedora live USB handy until the first signed boot succeeds.
EOF
}

sb_status() {
  need_root
  sb_config_load
  local esp
  esp="$(detect_esp)" || die "ESP not found."
  echo "${C_BLD}--- Secure Boot status ---${C_RST}"
  echo "firmware : $(secureboot_state | head -n1)"
  echo "config   : SECURE_BOOT=$SB_MODE verify=$SB_VERIFY enroll=$SB_ENROLL keys=$SB_KEYS"
  echo "keys     : $(sb_keys_present "$SB_KEYS" && echo "present ($SB_KEYS/MOK.{priv,pem,der})" || echo "MISSING")"
  echo "tool     : $(command -v "$LIMINE_TOOL" >/dev/null 2>&1 && echo "$LIMINE_TOOL" || echo "MISSING ($LIMINE_TOOL)")"
  echo "ESP      : $esp"
  local efi
  while IFS= read -r efi; do
    [[ -n "$efi" ]] || continue
    printf '  %s\n' "$efi"
    if command -v sbverify >/dev/null 2>&1 && sb_keys_present "$SB_KEYS"; then
      sbverify --cert "$SB_KEYS/MOK.pem" "$efi" >/dev/null 2>&1 \
        && echo "    signature: VALID (our key)" || echo "    signature: NOT ours/unsigned"
    fi
  done < <(sb_managed_efis "$esp")
  if [[ -f "$esp/limine.conf" ]]; then
    echo "conf b2 : $(b2sum "$esp/limine.conf" | cut -d' ' -f1 | cut -c1-32)… (full in log)"
    grep -c '#[0-9a-fA-F]\{64,\}' "$esp/limine.conf" | xargs echo "hashed paths:"
  else
    echo "conf     : MISSING ($esp/limine.conf)"
  fi
  if [[ -f "$esp/EFI/fedora/grubx64.efi.grub-bak" ]]; then
    echo "shim     : GRUB backup present (mok-shim copy active or was active)"
  fi
  nvidia_detect
  if [[ "$NVIDIA_PRESENT" -eq 1 ]]; then
    echo "nvidia   : $NVIDIA_SRC ${NVIDIA_VER:-} (signer: ${NVIDIA_SIGNER:-?}, key enrolled: $NVIDIA_ENROLLED)"
    if [[ "$NVIDIA_SRC" == "dkms" ]]; then
      local dkms_cn
      dkms_cn="$(grep '^mok_certificate=' "$DKMS_CONF" 2>/dev/null | cut -d'"' -f2 || true)"
      echo "dkms key : ${dkms_cn:-default /var/lib/dkms/mok.pub}"
    fi
  fi
}

sb_resign_flow() {
  need_root
  sb_config_load
  local esp
  esp="$(detect_esp)" || die "ESP not found."
  [[ -f "$SYNC_SCRIPT" ]] || die "Not installed ($SYNC_SCRIPT). Run install first."
  [[ "${SB_MODE:-no}" == "no" ]] && warn "SECURE_BOOT=no in $CONFIG_FILE — resign still re-hashes if verification is on."
  if [[ "$(firmware_type)" != "uefi" ]]; then die "Secure Boot is UEFI-only (this is BIOS)."; fi
  sb_ensure_tools "$SB_MODE"
  log "Re-syncing (hashes per config)..."
  run "$SYNC_SCRIPT" sync all
  if [[ "$SB_ENROLL" == "yes" ]]; then
    sb_enroll_and_sign "$esp" "$SB_KEYS"
  elif sb_keys_present "$SB_KEYS"; then
    warn "ENABLE_ENROLL_CONFIG!=yes — signing without re-enrolling conf hash."
    local efi
    while IFS= read -r efi; do
      [[ -n "$efi" ]] || continue
      sb_sign_file "$efi" "$SB_KEYS"
    done < <(sb_managed_efis "$esp")
  else
    warn "Nothing to sign (no keys, enroll disabled)."
  fi
  ok "Resign done. Verify: sudo $0 --sb-status"
}

sb_setup_mok() {
  # Assumes base install exists (ESP files + conf + tool).
  local esp="$1"
  SB_KEYS="${SB_KEYS:-$SB_KEY_DIR_DEFAULT}"; SB_CN="${SB_CN:-Fedora Limine Secure Boot}"
  sb_ensure_tools "mok-shim"
  sb_keygen "$SB_KEYS" "$SB_CN"
  sb_set_config "mok-shim"
  sb_config_load  # re-read (mode/enroll now on)
  nvidia_sb_setup
  log "Re-syncing kernels with file hashes..."
  run "$SYNC_SCRIPT" sync all
  sb_enroll_and_sign "$esp" "$SB_KEYS"
  sb_deploy_shim_copy "$esp"
  # The shim copy must be signed too (it was copied AFTER signing src — same
  # bytes, signature intact — but re-sign explicitly for certainty).
  sb_sign_file "$esp/EFI/fedora/grubx64.efi" "$SB_KEYS"
  echo
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  (dry-run) mokutil --import $SB_KEYS/MOK.der"
  elif [[ "$ASSUME_YES" -eq 1 ]]; then
    warn "--yes: skipping mokutil --import (needs a password + reboot). Run manually:"
    echo "  sudo mokutil --import $SB_KEYS/MOK.der"
  else
    echo "Set a MOK password (you will enter it ONCE in MokManager on next boot):"
    run mokutil --import "$SB_KEYS/MOK.der" || warn "mokutil --import failed (no efivars? re-run where ESP/firmware NVRAM exists)."
  fi
  sb_print_mok_instructions "$SB_KEYS"
}

sb_setup_db() {
  local esp="$1"
  SB_KEYS="${SB_KEYS:-$SB_KEY_DIR_DEFAULT}"; SB_CN="${SB_CN:-Fedora Limine Secure Boot}"
  sb_ensure_tools "custom-db"
  sb_keygen "$SB_KEYS" "$SB_CN"
  sb_set_config "custom-db"
  sb_config_load
  nvidia_sb_setup
  log "Re-syncing kernels with file hashes..."
  run "$SYNC_SCRIPT" sync all
  sb_enroll_and_sign "$esp" "$SB_KEYS"
  sb_print_db_guide "$SB_KEYS"
}

sb_setup_flow() {
  local method="${1:-ask}"
  need_root
  if [[ "$(firmware_type)" != "uefi" ]]; then die "Secure Boot setup is UEFI-only (this system is BIOS)."; fi
  local esp
  esp="$(detect_esp)" || die "ESP not found."
  [[ -f "$esp/EFI/limine/limine_x64.efi" ]] || die "Limine not deployed (run install first)."
  [[ -f "$CONFIG_FILE" ]] || die "No $CONFIG_FILE (run install first)."
  command -v "$LIMINE_TOOL" >/dev/null 2>&1 || die "limine tool missing ($LIMINE_TOOL). Re-run install."
  sb_config_load
  SB_KEYS="${SB_KEYS:-$SB_KEY_DIR_DEFAULT}"; SB_CN="${SB_CN:-Fedora Limine Secure Boot}"
  if [[ "$method" == "ask" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      method="mok-shim"
      warn "--yes: defaulting to mok-shim WITHOUT MOK import (run mokutil --import manually)."
    else
      echo
      echo "${C_BLD}--- Secure Boot setup ---${C_RST}"
      echo "  mok-shim   MOK key + shim chainload. No firmware Setup Mode. (Recommended)"
      echo "  custom-db  Enroll key into firmware db in Setup Mode. No shim. (Advanced)"
      echo "  no         Cancel."
      method="$(ask_with_default "Method" "mok-shim")"
    fi
  fi
  case "$method" in
    mok-shim|mok|shim) sb_setup_mok "$esp" ;;
    custom-db|db|direct) sb_setup_db "$esp" ;;
    no|none|cancel) log "Secure Boot setup cancelled."; return 0 ;;
    *) die "Unknown method: $method (use mok-shim or custom-db)." ;;
  esac
  ok "Secure Boot setup ($method) complete. Check: sudo $0 --sb-status"
}

secureboot_menu() {
  # Wizard choice. Sets DO_SECUREBOOT (no|mok-shim|custom-db). Never enrolls here.
  echo
  echo "${C_BLD}--- Secure Boot ---${C_RST}"
  echo "Firmware reports: $SB_STATE. Unsigned Limine boots only with SB off."
  echo "  no         Leave unsigned (default; pick --sb-setup later if SB turns on)."
  echo "  mok-shim   Sign + MOK enroll + shim chainload. (Recommended if SB is/will be on)"
  echo "  custom-db  Sign + firmware-db enrollment in Setup Mode. (Advanced)"
  local def="no"
  [[ "$SB_STATE" == "enabled" ]] && def="mok-shim"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    DO_SECUREBOOT="no"
    warn "--yes: Secure Boot stays unsigned (key enrollment needs interaction)."
    return 0
  fi
  if [[ "$(firmware_type)" != "uefi" ]]; then
    warn "BIOS firmware: Secure Boot N/A — skipping."
    DO_SECUREBOOT="no"
    return 0
  fi
  DO_SECUREBOOT="$(ask_with_default "Secure Boot method" "$def")"
  case "$DO_SECUREBOOT" in
    no|mok-shim|custom-db) ;;
    mok|shim) DO_SECUREBOOT="mok-shim" ;;
    db|direct) DO_SECUREBOOT="custom-db" ;;
    *) warn "Unknown '$DO_SECUREBOOT' — using 'no'."; DO_SECUREBOOT="no" ;;
  esac
}

# ------------------------------------------------- nvidia + SB ---------
# NVIDIA out-of-tree modules (nvidia*.ko, plus any other DKMS module such as
# WiFi) are rejected under SB lockdown unless signed by a MOK-enrolled key.
# Strategy: point DKMS at the SAME Limine MOK (one key, one enrollment),
# rebuild for every installed kernel, and keep the ESP in sync after DKMS
# rebuilds (DKMS dracut regens bypass kernel-install, so the ESP copy would
# otherwise go stale until the next kernel update).

DKMS_CONF="/etc/dkms/framework.conf"

nvidia_detect() {
  # Sets globals; safe without root (modinfo/lspci/dkms status are readable).
  NVIDIA_PRESENT=0; NVIDIA_SRC="none"; NVIDIA_VER=""; NVIDIA_SIGNER=""
  NVIDIA_KEY=""; NVIDIA_ENROLLED="unknown"; NVIDIA_DKMS_MODS=""
  command -v lspci >/dev/null 2>&1 || return 0
  lspci 2>/dev/null | grep -qi nvidia || return 0
  NVIDIA_PRESENT=1
  if command -v dkms >/dev/null 2>&1; then
    NVIDIA_DKMS_MODS="$(dkms status 2>/dev/null | grep -E '^[a-z0-9_.-]+/[0-9]' | cut -d, -f1 | sort -u | tr '\n' ' ' || true)"
    local nv
    nv="$(dkms status 2>/dev/null | grep -oE '^nvidia/[0-9][^,]*' | head -n1 | cut -d/ -f2 || true)"
    if [[ -n "$nv" ]]; then
      NVIDIA_SRC="dkms"; NVIDIA_VER="$nv"
      NVIDIA_SIGNER="$(modinfo -F signer nvidia 2>/dev/null || true)"
      [[ -f /var/lib/dkms/mok.pub ]] && NVIDIA_KEY="/var/lib/dkms/mok.pub"
    fi
  fi
  if [[ "$NVIDIA_SRC" == "none" ]] && rpm -q akmod-nvidia akmod-nvidia-open 2>/dev/null | grep -qv "not installed"; then
    NVIDIA_SRC="rpm-akmods"
    NVIDIA_VER="$(rpm -q akmod-nvidia akmod-nvidia-open 2>/dev/null | head -n1 || true)"
    NVIDIA_SIGNER="$(modinfo -F signer nvidia 2>/dev/null || true)"
    [[ -f /etc/pki/akmods/certs/public_key.der ]] && NVIDIA_KEY="/etc/pki/akmods/certs/public_key.der"
  fi
  if [[ -n "${NVIDIA_KEY:-}" && -f "$NVIDIA_KEY" ]]; then
    local out
    out="$(mokutil --test-key "$NVIDIA_KEY" 2>&1 || true)"
    if echo "$out" | grep -q "is not enrolled"; then
      NVIDIA_ENROLLED="no"
    elif echo "$out" | grep -q "is enrolled"; then
      NVIDIA_ENROLLED="yes"
    fi
  fi
}

nvidia_preflight_report() {
  nvidia_detect
  echo "--- NVIDIA ---"
  if [[ "$NVIDIA_PRESENT" -eq 0 ]]; then
    echo "No NVIDIA GPU detected (lspci) — skipping."
    return 0
  fi
  echo "GPU+driver: $NVIDIA_SRC ${NVIDIA_VER:-} (signer: ${NVIDIA_SIGNER:-none/unsigned})"
  echo "DKMS modules: ${NVIDIA_DKMS_MODS:-none}"
  echo "module key : ${NVIDIA_KEY:-none} (enrolled: $NVIDIA_ENROLLED)"
  echo "lockdown   : $(cat /sys/kernel/security/lockdown 2>/dev/null || echo n/a)"
  if [[ "$NVIDIA_ENROLLED" == "no" ]]; then
    warn "NVIDIA/DKMS key NOT enrolled: enabling SB now = black screen + no WiFi until fixed."
    echo "  The SB setup offers one-key unification (recommended)."
  fi
}

nvidia_menu() {
  # Called inside SB setup (keys exist). Decides unification. Sets DO_NVIDIA.
  DO_NVIDIA="skip"
  nvidia_detect
  if [[ "$NVIDIA_PRESENT" -eq 0 ]]; then return 0; fi
  echo
  echo "${C_BLD}--- NVIDIA Secure Boot ---${C_RST}"
  echo "Driver: $NVIDIA_SRC $NVIDIA_VER (modules signed by '${NVIDIA_SIGNER:-?}', key enrolled: $NVIDIA_ENROLLED)"
  if [[ "$NVIDIA_SRC" == "dkms" ]]; then
    echo "Plan: point DKMS at your Limine MOK ($SB_KEYS), rebuild modules for"
    echo "all kernels, enroll once (covers Limine + NVIDIA + WiFi DKMS modules)."
    local ans
    if [[ "$ASSUME_YES" -eq 1 ]]; then ans="yes"; else ans="$(ask_with_default "Unify DKMS signing key?" "yes")"; fi
    [[ "$ans" == [yY]* ]] && DO_NVIDIA="unify" || DO_NVIDIA="skip"
  elif [[ "$NVIDIA_SRC" == "rpm-akmods" ]]; then
    echo "RPM Fusion akmods uses its own key ($NVIDIA_KEY). Plan: enroll it"
    echo "alongside the Limine MOK in the same MokManager session (two imports)."
    local ans
    if [[ "$ASSUME_YES" -eq 1 ]]; then ans="yes"; else ans="$(ask_with_default "Enroll akmods key too?" "yes")"; fi
    [[ "$ans" == [yY]* ]] && DO_NVIDIA="enroll-akmods" || DO_NVIDIA="skip"
  else
    warn "NVIDIA present but driver source unclear (neither DKMS nor akmods)."
    warn "Sign modules manually (sign-file + mokutil --import), then continue."
    DO_NVIDIA="skip"
  fi
}

nvidia_unify_key() {
  # Point DKMS at the Limine MOK. Idempotent via marker comment.
  local keydir="$1"
  [[ -f "$DKMS_CONF" ]] || die "No $DKMS_CONF (is DKMS installed?)"
  if grep -q 'managed by fedora-limine-switch' "$DKMS_CONF" 2>/dev/null; then
    ok "DKMS already points at Limine key (marker present)."
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) backup $DKMS_CONF + set mok_signing_key/certificate"; return 0; fi
  run cp -a "$DKMS_CONF" "$DKMS_CONF.limine-bak-$(date +%F-%H%M%S)"
  # Drop conflicting lines, then append ours (last assignment wins in DKMS).
  run sed -i '/^mok_signing_key=/d; /^mok_certificate=/d' "$DKMS_CONF"
  {
    echo '# managed by fedora-limine-switch (one MOK for Limine + DKMS modules)'
    echo "mok_signing_key=\"$keydir/MOK.priv\""
    echo "mok_certificate=\"$keydir/MOK.pem\""
  } >> "$DKMS_CONF"
  ok "DKMS now signs with the Limine MOK."
}

nvidia_needs_rebuild() {
  # $1 = kernel ver, $2 = expected signer CN. Returns 0 (rebuild) or 1 (ok).
  local ver="$1" expect="$2" f s
  f="$(find "/lib/modules/$ver/extra" -name 'nvidia.ko*' 2>/dev/null | head -n1 || true)"
  [[ -z "$f" ]] && return 0
  s="$(modinfo -F signer "$f" 2>/dev/null || true)"
  [[ "$s" != *"$expect"* ]]
}

nvidia_rebuild_all() {
  # Rebuild DKMS modules only for kernels needing it. $1 = expected signer CN.
  local expect="$1" ver built=0 skipped=0
  for b in /lib/modules/*/build; do
    ver="$(basename "$(dirname "$b")")"
    if nvidia_needs_rebuild "$ver" "$expect"; then
      log "DKMS rebuild for $ver (nvidia: missing or wrong signer)..."
      if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) dkms autoinstall -k $ver"; continue; fi
      run dkms autoinstall -k "$ver" || warn "dkms autoinstall failed for $ver (see dkms status)"
      built=$((built + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  ok "DKMS rebuild done (rebuilt: $built, already-good: $skipped)."
  if [[ "$DRY_RUN" -eq 0 ]]; then dkms status 2>/dev/null | head -n 10 || true; fi
}

nvidia_verify() {
  # Report per-kernel nvidia signer. Warns, never fails.
  local ver f s
  for b in /lib/modules/*/build; do
    ver="$(basename "$(dirname "$b")")"
    f="$(find "/lib/modules/$ver/extra" -name 'nvidia.ko*' 2>/dev/null | head -n1 || true)"
    if [[ -z "$f" ]]; then echo "  $ver: no nvidia module"; continue; fi
    s="$(modinfo -F signer "$f" 2>/dev/null || echo ERROR)"
    echo "  $ver: signer='$s'"
  done
}

dkms_esp_hook_install() {
  # DKMS post_transaction dracut regens bypass kernel-install: append an ESP
  # re-sync so Limine never serves a stale initramfs after driver rebuilds.
  [[ -f "$DKMS_CONF" ]] || { warn "no $DKMS_CONF, skipping ESP hook"; return 0; }
  if grep -q 'limine-esp-sync' "$DKMS_CONF" 2>/dev/null; then
    ok "DKMS ESP hook already present."
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) append limine sync to post_transaction in $DKMS_CONF"; return 0; fi
  # Backup once (ls-test avoids [[ -f glob ]] multi-match hazards).
  ls "$DKMS_CONF".limine-bak-* >/dev/null 2>&1 || run cp -a "$DKMS_CONF" "$DKMS_CONF.limine-bak-$(date +%F-%H%M%S)"
  if grep -q '^post_transaction=' "$DKMS_CONF"; then
    # Append inside the existing quoted command ($kernelver stays literal for
    # DKMS eval time — single-quoted sed, % delimiter avoids | and # clashes).
    run sed -i 's%^post_transaction="\(.*\)"%post_transaction="\1; /usr/local/sbin/limine-fedora-sync sync $kernelver || true # limine-esp-sync"%' "$DKMS_CONF"
  else
    {
      echo '# managed by fedora-limine-switch (keep ESP in sync after DKMS rebuilds)'
      echo 'post_transaction="dracut --regenerate-all --force; /usr/local/sbin/limine-fedora-sync sync $kernelver || true # limine-esp-sync"'
    } >> "$DKMS_CONF"
  fi
  grep '^post_transaction=' "$DKMS_CONF" | head -n 3
  ok "DKMS ESP hook installed (re-syncs Limine after every DKMS rebuild)."
}

dkms_esp_hook_remove() {
  if grep -q 'limine-esp-sync' "$DKMS_CONF" 2>/dev/null; then
    if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) remove limine lines from $DKMS_CONF"; return 0; fi
    local bak
    bak="$(ls -t "$DKMS_CONF.limine-bak-"* 2>/dev/null | head -n1 || true)"
    if [[ -n "$bak" ]]; then
      run cp -a "$bak" "$DKMS_CONF"
      ok "DKMS conf restored from $bak."
    else
      run sed -i '/limine-esp-sync/d; /managed by fedora-limine-switch/d' "$DKMS_CONF"
      ok "DKMS hook lines removed (no backup found)."
    fi
  fi
}

nvidia_sb_setup() {
  # Full NVIDIA step inside SB setup. Requires SB_KEYS/SB_CN globals + keys made.
  nvidia_menu
  case "${DO_NVIDIA:-skip}" in
    unify)
      nvidia_unify_key "$SB_KEYS"
      nvidia_rebuild_all "$SB_CN"
      nvidia_verify || true
      dkms_esp_hook_install
      ;;
    enroll-akmods)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  (dry-run) mokutil --import $NVIDIA_KEY"
      elif [[ "$ASSUME_YES" -eq 1 ]]; then
        warn "--yes: run manually: sudo mokutil --import $NVIDIA_KEY"
      else
        echo "Same MOK password as the Limine key (one session enrolls both):"
        run mokutil --import "$NVIDIA_KEY" || warn "akmods key import failed."
      fi
      ;;
    *) log "NVIDIA unification skipped." ;;
  esac
}

# ---------------------------------------------------------------- extras ----

extras_menu() {
  echo
  echo "${C_BLD}--- Optional extras (CachyOS full-suite parity) ---${C_RST}"
  echo "All optional. Defaults in [brackets]. Non-interactive (--yes) picks defaults."

  DO_MEMTEST="$(ask_with_default "Install memtest86+ + add menu entry? (yes/no)" "yes")"
  DO_SHELL="$(ask_with_default "Install EDK2 UEFI Shell + add menu entry? (yes/no)" "no")"
  DO_SNAPSHOTS="$(ask_with_default "Enable snapper/BTRFS snapshot entries if BTRFS? (yes/no)" "yes")"
  DO_THEME="$(ask_with_default "Apply Catppuccin theme palette (already default) + try splash image? (yes/no)" "no")"

  [[ "$DO_MEMTEST" == [yY]* ]] && DO_MEMTEST=1 || DO_MEMTEST=0
  [[ "$DO_SHELL" == [yY]* ]] && DO_SHELL=1 || DO_SHELL=0
  [[ "$DO_SNAPSHOTS" == [yY]* ]] && DO_SNAPSHOTS=1 || DO_SNAPSHOTS=0
  [[ "$DO_THEME" == [yY]* ]] && DO_THEME=1 || DO_THEME=0
}

install_extras() {
  local esp="$1"
  if [[ "$DO_MEMTEST" -eq 1 ]]; then
    log "Installing memtest86+..."
    if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) dnf install memtest86+ + copy to ESP"; else
      dnf install -y memtest86+ 2>/dev/null || warn "memtest86+ install failed (skipping)."
      # Fedora layout: /usr/lib64/memtest86+/memtest86+x64.efi (also /usr/share/memtest86+/*.iso)
      local m
      m="$(find /usr/lib64/memtest86+ /usr/share/memtest86+ /usr/share -maxdepth 4 -iname '*memtest*x64.efi' 2>/dev/null | head -n1 || true)"
      if [[ -n "$m" ]]; then
        mkdir -p "$esp/EFI/memtest86+"
        cp -v "$m" "$esp/EFI/memtest86+/memtest86x64.efi"
      else
        warn "memtest EFI binary not found after install; entry will appear once the file exists on ESP."
      fi
    fi
  fi
  if [[ "$DO_SHELL" -eq 1 ]]; then
    log "Installing EDK2 shell..."
    if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) dnf install edk2-shell-x64 + copy Shell.efi"; else
      dnf install -y edk2-shell-x64 2>/dev/null || warn "edk2-shell-x64 install failed (skipping)."
      # Fedora layout: /usr/share/edk2/ovmf/Shell.efi
      local s
      s="$(find /usr/share/edk2 /usr/share -maxdepth 5 -iname 'Shell.efi' -o -iname 'shellx64.efi' 2>/dev/null | head -n1 || true)"
      if [[ -n "$s" ]]; then
        mkdir -p "$esp/EFI/tools"
        cp -v "$s" "$esp/EFI/tools/Shell.efi"
      else
        warn "Shell.efi not found; download from EDK2 releases to $esp/EFI/tools/Shell.efi manually."
      fi
    fi
  fi
  if [[ "$DO_SNAPSHOTS" -eq 1 ]]; then
    local rootfs
    rootfs="$(findmnt -n -o FSTYPE / 2>/dev/null || echo ?)"
    if [[ "$rootfs" != "btrfs" ]]; then
      warn "Root is $rootfs (not btrfs) — snapshot entries skipped (nothing to do)."
    else
      log "Setting up snapper snapshot support (BTRFS detected)..."
      if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) dnf install snapper btrfs-progs + enable"; else
        dnf install -y snapper btrfs-progs inotify-tools 2>/dev/null || warn "snapper install failed."
        warn "Snapshot entry auto-generation is minimal on Fedora (CachyOS limine-snapper-sync"
        warn "has no Fedora port yet). Manual step: create snapper config + keep $esp/limine-snapshots.conf"
        warn "in sync (see README 'Snapshots'). Base hook above will include it once present."
      fi
    fi
  fi
  if [[ "$DO_THEME" -eq 1 ]]; then
    log "Theme: Catppuccin palette is already in limine.conf defaults."
    warn "Splash: place a  PNG at /boot/limine-splash.png then run: sudo limine-update"
  fi
  # Re-render conf so new ESP files (memtest/shell) are picked up.
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "$SYNC_SCRIPT" conf-only || true
  fi
}

# ---------------------------------------------------------------- backup ----

do_backup() {
  local ts dest
  ts="$(date +%F-%H%M%S)"
  dest="$BACKUP_ROOT/$ts"
  log "Backing up to $dest ..."
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "  (dry-run) backup ESP EFI dirs + /boot/loader + efibootmgr -v"; return 0; fi
  mkdir -p "$dest"
  efibootmgr -v > "$dest/efibootmgr-v.txt" 2>&1 || true
  cp -a /etc/kernel/cmdline "$dest/kernel-cmdline.txt" 2>/dev/null || echo "(no /etc/kernel/cmdline)" > "$dest/kernel-cmdline.txt"
  cat /proc/cmdline > "$dest/proc-cmdline.txt" 2>/dev/null || true
  cp -a /etc/default/grub "$dest/default-grub.bak" 2>/dev/null || true
  if [[ -d "$ESP/EFI" ]]; then
    # vfat -> tar to preserve DOS attrs; failures tolerated.
    tar -czf "$dest/esp-EFI-backup.tgz" -C "$ESP" EFI 2>/dev/null || cp -a "$ESP/EFI" "$dest/esp-EFI" 2>/dev/null || true
  fi
  if [[ -d /boot/loader/entries ]]; then
    mkdir -p "$dest/loader-entries"
    cp -a /boot/loader/entries/. "$dest/loader-entries/" 2>/dev/null || true
  fi
  # Existing limine.conf(s) if re-running.
  for f in "$ESP/limine.conf" "$ESP/EFI/limine/limine.conf" "$ESP/EFI/BOOT/limine.conf"; do
    [[ -f "$f" ]] || continue
    mkdir -p "$dest/esp-conf"
    cp -v "$f" "$dest/esp-conf/$(echo "$f" | tr '/' '_')" || true
  done
  echo "$ESP" > "$dest/esp-path.txt"
  ok "Backup complete: $dest"
  BACKUP_DEST="$dest"
}

# ---------------------------------------------------------------- verify ----

verify_install() {
  local esp="$1"
  echo
  echo "${C_BLD}--- Verify ---${C_RST}"
  echo "ESP contents:"
  ls -lh "$esp/EFI/limine/" 2>/dev/null || warn "missing $esp/EFI/limine/"
  ls -lh "$esp/$MACHINE/" 2>/dev/null || ls -lh "$esp/$(machine_id)/" 2>/dev/null || warn "no per-machine kernel dir yet"
  echo
  echo "limine.conf (first 60 lines):"
  head -n 60 "$esp/limine.conf" 2>/dev/null || warn "no $esp/limine.conf"
  echo
  efibootmgr 2>/dev/null || warn "efibootmgr unavailable"
  echo
  if [[ -f "$esp/EFI/limine/limine_x64.efi" && -f "$esp/limine.conf" ]]; then
    ok "Limine looks deployed. Next: reboot, pick 'Limine' (or it boots first), test ALL kernels."
  else
    err "Something is missing — see log: $LOG_FILE"
  fi
  # Secure Boot summary (if configured).
  if [[ -f "$CONFIG_FILE" ]]; then
    local sbmode hashed
    sbmode="$(grep '^SECURE_BOOT=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    if [[ -n "${sbmode:-}" && "$sbmode" != "no" ]]; then
      echo
      echo "Secure Boot ($sbmode): firmware reports $(secureboot_state | head -n1)"
      hashed="$(grep -c '#[0-9a-fA-F]\{64,\}' "$esp/limine.conf" 2>/dev/null || true)"
      echo "  hashed paths in limine.conf: $hashed"
      local keydir
      keydir="$(grep '^SB_KEY_DIR=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
      [[ -z "${keydir:-}" ]] && keydir="$SB_KEY_DIR_DEFAULT"
      if [[ -f "$keydir/MOK.pem" ]] && command -v sbverify >/dev/null 2>&1; then
        if sbverify --cert "$keydir/MOK.pem" "$esp/EFI/limine/limine_x64.efi" >/dev/null 2>&1; then
          ok "  signature on limine_x64.efi: VALID (our key)"
        else
          warn "  signature on limine_x64.efi: NOT valid with our key (re-run --sb-resign)"
        fi
      else
        warn "  cannot verify signature (keys/sbverify missing)"
      fi
      [[ "$sbmode" == "mok-shim" && -f "$esp/EFI/fedora/grubx64.efi.grub-bak" ]] \
        && echo "  shim chain: active (real GRUB in .grub-bak)" \
        || echo "  shim chain: no GRUB backup (direct boot only)"
      nvidia_detect
      if [[ "$NVIDIA_PRESENT" -eq 1 ]]; then
        echo "  nvidia module: ${NVIDIA_SIGNER:-unsigned?} (key enrolled: $NVIDIA_ENROLLED)"
      fi
    fi
  fi
}

print_next_steps() {
  cat <<EOF

${C_BLD}Next steps (read this!):${C_RST}
  1. Reboot. Limine should be first in boot order; old Fedora/GRUB entry is kept.
  2. Test every kernel entry in Limine. Keep GRUB until you're sure.
  3. Kernel updates: automatic via $HOOK_FILE (runs limine-fedora-sync).
     After editing $CONFIG_FILE, run:  sudo limine-update
  4. Rollback any time: firmware boot menu -> pick "Fedora" (GRUB),
     or: sudo efibootmgr -o <fedora-num>,<limine-num>
     Full uninstall: sudo $0 --uninstall
  5. (Optional) Only when Limine is proven: remove GRUB (see README "Removing GRUB").
     Do NOT remove shim/grub blindly — they are dnf-protected for a reason.
EOF
  # SB-specific next steps (only when configured).
  if [[ -f "$CONFIG_FILE" ]]; then
    local sbmode
    sbmode="$(grep '^SECURE_BOOT=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    if [[ -n "${sbmode:-}" && "$sbmode" != "no" ]]; then
      if [[ "$sbmode" == "mok-shim" ]]; then
        echo
        echo "Secure Boot (mok-shim): on the NEXT boot, MokManager (blue screen) asks"
        echo "  to enroll your MOK — complete it, then boot via the 'Fedora' (shim)"
        echo "  entry. Every kernel/conf update re-signs automatically via the hook."
      else
        echo
        echo "Secure Boot (custom-db): enroll your key in firmware Setup Mode"
        echo "  (see README), then: sudo $0 --sb-resign"
      fi
    fi
  fi
  cat <<EOF2

Log: $LOG_FILE
Backup: ${BACKUP_DEST:-$BACKUP_ROOT/<timestamp>}
Docs: README.md (Secure Boot, snapshots, troubleshooting, GRUB removal)
EOF2
}

# ---------------------------------------------------------------- uninstall

do_uninstall() {
  banner
  echo "Rollback / uninstall mode."
  need_root
  local esp
  esp="$(detect_esp)" || die "ESP not found."
  echo "ESP: $esp"
  efibootmgr -v 2>/dev/null | head -n 30 || true
  warn "This will:"
  echo "  - Move the Fedora/GRUB entry back to FIRST in BootOrder (Limine kept, deprioritized),"
  echo "  - Optionally delete Limine NVRAM entry, ESP files, hook + scripts, $CONFIG_FILE."
  confirm "Continue with rollback?" || die "Aborted."
  local fedora_num limine_num order rest
  fedora_num="$(efibootmgr 2>/dev/null | grep -i 'fedora' | head -n1 | grep -o '[0-9A-Fa-f]\{4\}' | head -n1 || true)"
  limine_num="$(efibootmgr 2>/dev/null | grep -i 'limine' | head -n1 | grep -o '[0-9A-Fa-f]\{4\}' | head -n1 || true)"
  if [[ -n "$fedora_num" ]]; then
    order="$(efibootmgr 2>/dev/null | grep '^BootOrder:' | awk '{print $2}' || true)"
    rest="$(echo "$order" | tr ',' '\n' | grep -vi "^$fedora_num\$" | paste -sd, - || true)"
    log "Restoring BootOrder: $fedora_num,$rest"
    run efibootmgr -o "$fedora_num,$rest" || warn "Could not set BootOrder."
  else
    warn "No Fedora NVRAM entry found; set boot order manually in firmware."
  fi
  if confirm "Delete the Limine NVRAM entry (Boot$limine_num)?"; then
    [[ -n "$limine_num" ]] && run efibootmgr -b "$limine_num" -B || warn "No Limine entry to delete."
  fi
  if confirm "Remove Limine ESP files + hook + scripts + $CONFIG_FILE? (GRUB packages untouched)"; then
    if [[ -f "$esp/EFI/fedora/grubx64.efi.grub-bak" ]]; then
      if confirm "Restore real GRUB over the mok-shim copy?"; then
        run cp -v "$esp/EFI/fedora/grubx64.efi.grub-bak" "$esp/EFI/fedora/grubx64.efi" \
          || warn "GRUB restore failed."
      else
        warn "Leaving signed Limine as grubx64.efi (GRUB backup kept at .grub-bak)."
      fi
    fi
    run rm -rf "$esp/EFI/limine" "$esp/$(machine_id)" "$esp/limine.conf" \
      "$esp/EFI/limine/limine.conf" "$esp/EFI/BOOT/limine.conf" "$esp/limine-splash.png" || true
    # Only remove our fallback if it is actually Limine (check size/signature loosely: keep .limine-bak files).
    warn "Leaving EFI/BOOT/BOOTX64.EFI in place unless you confirm it is Limine's (a shim backup may exist alongside)."
    if confirm "Also remove EFI/BOOT/BOOTX64.EFI fallback copy? (only if you KNOW it is Limine's)"; then
      run rm -f "$esp/EFI/BOOT/BOOTX64.EFI" || true
    fi
    run rm -f "$HOOK_FILE" "$SYNC_SCRIPT" "$UPDATE_WRAPPER" "$CONFIG_FILE" "$LIMINE_TOOL" || true
    if grep -q 'limine-esp-sync\|managed by fedora-limine-switch' "$DKMS_CONF" 2>/dev/null; then
      if confirm "Revert DKMS signing key + ESP hook to pre-install backup?"; then
        dkms_esp_hook_remove
        warn "If modules were rebuilt with the Limine key, re-run: dkms autoinstall"
      fi
    fi
    if [[ -d "$SB_KEY_DIR_DEFAULT" ]] && confirm "Also delete Secure Boot keys in $SB_KEY_DIR_DEFAULT? (MOK stays enrolled; keeping is safer)"; then
      run rm -rf "$SB_KEY_DIR_DEFAULT" || true
    fi
    ok "Limine files removed. GRUB/shim packages were NOT touched (reinstall if needed: dnf install grub2-efi-x64 shim-x64)."
  fi
  ok "Rollback done. Reboot and verify Fedora/GRUB boots."
}

# ---------------------------------------------------------------- main ------

main() {
  need_root

  if [[ "$MODE" == "uninstall" ]]; then do_uninstall; exit 0; fi

  # Shared state
  ESP=""; MACHINE=""; LIMINE_VER=""; LIMINE_SRC=""; ESP_DISK=""; ESP_SRC=""; WORKDIR=""
  DO_FALLBACK=1; DO_EFIBOOTMGR=1; DO_DUALBOOT_SCAN=1; DO_SNAPSHOTS=1; DO_BIOS=0
  DO_SNAPSHOTS_CFG="auto"
  DO_MEMTEST=0; DO_SHELL=0; DO_THEME=0
  DO_SECUREBOOT="no"; SB_STATE="unknown"
  SB_KEY_DIR="$SB_KEY_DIR_DEFAULT"; SB_CN="Fedora Limine Secure Boot"
  DO_NVIDIA="skip"
  BACKUP_DEST=""

  preflight  # sets ESP (global)
  MACHINE="$(machine_id)"

  if [[ "$MODE" == "check" ]]; then
    ok "Preflight-only mode: no changes made."
    exit 0
  fi

  if [[ "$MODE" == "update" ]]; then
    log "Update mode: re-sync + regenerate (no reinstall of binaries)."
    [[ -f "$SYNC_SCRIPT" ]] || die "Not installed yet ($SYNC_SCRIPT missing). Run install mode first."
    [[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" || true
    run "$SYNC_SCRIPT" sync all
    ok "Update complete."
    exit 0
  fi

  if [[ "$MODE" == "sb-status" ]]; then
    sb_status
    exit 0
  fi

  if [[ "$MODE" == "sb-resign" ]]; then
    sb_resign_flow
    exit 0
  fi

  if [[ "$MODE" == "sb-setup" ]]; then
    sb_setup_flow "$SB_SETUP_METHOD"
    exit 0
  fi

  # ---- install wizard -------------------------------------------------------
  echo
  echo "${C_BLD}Install plan:${C_RST}"
  echo "  ESP: $ESP   machine-id: $MACHINE"
  echo "  1) backup  2) deps  3) download Limine  4) deploy EFI  5) config + hook"
  echo "  6) sync kernels  7) NVRAM (Limine first, GRUB kept)  8) extras  9) verify"
  echo "  GRUB removal is NEVER automatic."
  confirm "Start the install?" || die "Aborted. No changes made."

  # Basic choices up front (idiot-proof defaults).
  echo
  DO_FALLBACK="$(ask_with_default "Install fallback EFI/BOOT/BOOTX64.EFI copy? (yes/no)" "yes")"
  DO_EFIBOOTMGR="$(ask_with_default "Create 'Limine' NVRAM entry + put it first? (yes/no)" "yes")"
  DO_DUALBOOT_SCAN="$(ask_with_default "Auto-add Windows/other EFI entries if found? (yes/no)" "yes")"
  [[ "$DO_FALLBACK" == [yY]* ]] && DO_FALLBACK=1 || DO_FALLBACK=0
  [[ "$DO_EFIBOOTMGR" == [yY]* ]] && DO_EFIBOOTMGR=1 || DO_EFIBOOTMGR=0
  [[ "$DO_DUALBOOT_SCAN" == [yY]* ]] && DO_DUALBOOT_SCAN=1 || DO_DUALBOOT_SCAN=0
  if [[ "$(firmware_type)" == "bios" ]]; then
    DO_BIOS="$(ask_with_default "Also do BIOS (limine bios-install) stage? (yes/no)" "no")"
    [[ "$DO_BIOS" == [yY]* ]] && DO_BIOS=1 || DO_BIOS=0
  else
    DO_BIOS=0
  fi

  extras_menu  # sets DO_MEMTEST/DO_SHELL/DO_SNAPSHOTS/DO_THEME (0/1)
  # Map snapshots choice into config semantics (hook reads yes/auto).
  if [[ "$DO_SNAPSHOTS" -eq 1 ]]; then DO_SNAPSHOTS_CFG="auto"; else DO_SNAPSHOTS_CFG="no"; fi
  DO_SNAPSHOTS="$DO_SNAPSHOTS_CFG"

  secureboot_menu  # sets DO_SECUREBOOT (no|mok-shim|custom-db); never enrolls here

  do_backup
  install_deps

  LIMINE_VER="$(ask_with_default "Limine version (enter for latest auto-detect, fallback $LIMINE_FALLBACK_VERSION)" "latest")"
  if [[ "$LIMINE_VER" == "latest" ]]; then
    LIMINE_VER="$(latest_limine_version)"
    log "Latest Limine: $LIMINE_VER"
  fi
  WORKDIR="$(mktemp -d /tmp/fedora-limine-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$WORKDIR'" EXIT
  fetch_limine "$LIMINE_VER" "$WORKDIR"

  # Persist the `limine` host tool (needed for bios-install + enroll-config).
  if [[ -x "$LIMINE_SRC/limine" ]]; then
    log "Installing limine host tool -> $LIMINE_TOOL ..."
    run cp -v "$LIMINE_SRC/limine" "$LIMINE_TOOL"
    run chmod +x "$LIMINE_TOOL"
  else
    warn "limine host tool not built (BIOS install + Secure Boot enroll unavailable)."
  fi

  # Resolve ESP disk for later (BIOS prompt + info).
  ESP_SRC="$(esp_source "$ESP")"
  ESP_DISK="/dev/$(lsblk -n -o PKNAME "$ESP_SRC" 2>/dev/null | head -n1 || echo '?')"

  deploy_uefi "$ESP" "$LIMINE_SRC"
  if [[ "$DO_BIOS" -eq 1 ]]; then deploy_bios "$LIMINE_SRC"; fi

  write_default_config
  install_hook_and_sync_script
  sync_all_kernels
  register_efibootmgr "$ESP"
  # extras need 0/1 ints; DO_SNAPSHOTS currently "auto"/"no" -> map back for installer.
  if [[ "$DO_SNAPSHOTS" == "auto" ]]; then DO_SNAPSHOTS=1; else DO_SNAPSHOTS=0; fi
  install_extras "$ESP"
  if [[ "$DO_SECUREBOOT" != "no" ]]; then
    # Re-read key dir (existing config may define a custom one we kept).
    SB_KEYS="$(grep '^SB_KEY_DIR=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    [[ -z "${SB_KEYS:-}" ]] && SB_KEYS="$SB_KEY_DIR"
    case "$DO_SECUREBOOT" in
      mok-shim) sb_setup_mok "$ESP" ;;
      custom-db) sb_setup_db "$ESP" ;;
    esac
  fi
  verify_install "$ESP"
  print_next_steps
}

main "$@"

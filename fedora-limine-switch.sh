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
#   sudo ./fedora-limine-switch.sh --theme[=name]  # install/switch boot theme (default: ask)
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
STATE_FILE="/etc/limine/install-state.conf"
THEME_SNIPPET="/etc/limine/theme.conf"

DRY_RUN=0
ASSUME_YES=0
MODE="install"
SB_SETUP_METHOD="ask"
THEME_METHOD="ask"

# ------------------------------------------------------- colors + visuals ----

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'
  C_MAG=$'\e[35m'; C_CYN=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
  C_DIM=$'\e[2m'; C_GRY=$'\e[90m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_MAG=""; C_CYN=""; C_BLD=""
  C_RST=""; C_DIM=""; C_GRY=""
fi

# Terminal width for section rules (capped — long rules look silly on wide screens).
term_cols() {
  local c="${COLUMNS:-}"
  [[ "$c" =~ ^[0-9]+$ ]] || c="$(tput cols 2>/dev/null || echo 80)"
  (( c > 100 )) && c=100
  (( c < 40 )) && c=40
  printf '%s' "$c"
}

# Status lines: coloured on the terminal, plain text in the log file.
# (Redirects on the brace group, so an unwritable log never kills the script.)
_ui() {
  { printf '%s\n' "$2" >> "$LOG_FILE"; } 2>/dev/null || true
  printf '%s\n' "$1" >&2
}
log()  { _ui "${C_CYN}  ·${C_RST} $*" "  · $*"; }
ok()   { _ui "${C_GRN} [✔]${C_RST} $*" " [✔] $*"; }
warn() { _ui "${C_YLW} [⚠]${C_RST} $*" " [⚠] $*"; }
err()  { _ui "${C_RED} [✖]${C_RST} $*" " [✖] $*"; }
die()  { err "$*"; exit 1; }

# `── Section title ─────…` header.
section() {
  local LC_ALL=C.UTF-8   # count characters, not bytes (em dashes etc.)
  local title="$*" pad rule
  pad=$(( $(term_cols) - ${#title} - 4 ))   # 4 = "── " prefix + trailing space
  (( pad < 3 )) && pad=3
  printf -v rule '%*s' "$pad" ''
  printf '\n%s── %s %s%s%s\n' "$C_BLD$C_CYN" "$title" "${rule// /─}" "$C_RST"
}

# Smaller header inside a section.
subhead() { printf '\n  %s%s%s\n' "$C_BLD" "$*" "$C_RST"; }

# Aligned "label : value" info line; status-ish values get colour.
kv() {
  local label="$1" value="$2" paint=""
  case "$value" in
    *MISSING*|*PENDING*|*'NOT '*|*'not '*|*'unknown'*|*'failed'*) paint="$C_YLW" ;;
    *ENROLLED*|*VALID*|*'present'*|*'active'*|*'yes'*)            paint="$C_GRN" ;;
  esac
  printf '  %s%-13s:%s %s%s%s\n' "$C_DIM" "$label" "$C_RST" "$paint" "$value" "$C_RST"
}

# Dim, indented note; wraps to the terminal width.
hint() {
  local cols
  cols="$(term_cols)"
  printf '%s\n' "$*" | fold -s -w "$((cols - 4))" \
    | while IFS= read -r l; do printf '    %s%s%s\n' "$C_DIM" "$l" "$C_RST"; done
}
bullet() { printf '  %s•%s %s\n' "$C_CYN" "$C_RST" "$*"; }

# "▸ Step 3/10  Download Limine" progress marker for the install wizard.
# Pass "-" as the step number to print a plain marker without the counter.
phase() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    printf '\n  %s▸ Step %s/%s%s  %s%s%s\n' "$C_CYN$C_BLD" "$1" "$2" "$C_RST" "$C_BLD" "$3" "$C_RST"
  else
    printf '\n  %s▸%s  %s%s%s\n' "$C_CYN$C_BLD" "$C_RST" "$C_BLD" "$3" "$C_RST"
  fi
}

# Indent raw command output (efibootmgr, ls, rpm, …) so it sits inside a section.
ui_indent() { sed 's/^/  /'; }

# efibootmgr -v without the unreadable device-path hex dumps.
efi_list() { efibootmgr -v 2>/dev/null | grep -Ev '^[[:space:]]+(dp|data):'; }

dry_print() { printf '  %s(dry-run)%s %s\n' "$C_YLW" "$C_RST" "$*"; }

banner() {
  local LC_ALL=C.UTF-8   # count characters, not bytes (→ and — are 3 bytes)
  local l1="Fedora → Limine switcher"
  local l2="Swap GRUB for Limine — GRUB stays as fallback."
  local w=$(( ${#l1} > ${#l2} ? ${#l1} : ${#l2} )) bar pad1 pad2
  # NOTE: printf '%-*s' pads by BYTES, so pad spaces are built separately.
  printf -v bar '%*s' "$((w + 2))" ''
  printf -v pad1 '%*s' "$(( w - ${#l1} ))" ''
  printf -v pad2 '%*s' "$(( w - ${#l2} ))" ''
  bar="${bar// /─}"
  printf '\n%s╭%s╮%s\n' "$C_CYN$C_BLD" "$bar" "$C_RST"
  printf '%s│%s %s%s%s%s %s│%s\n' "$C_CYN$C_BLD" "$C_RST" "$C_BLD" "$l1" "$pad1" "$C_RST" "$C_CYN$C_BLD" "$C_RST"
  printf '%s│%s %s%s%s%s %s│%s\n' "$C_CYN$C_BLD" "$C_RST" "$C_DIM" "$l2" "$pad2" "$C_RST" "$C_CYN$C_BLD" "$C_RST"
  printf '%s╰%s╯%s\n' "$C_CYN$C_BLD" "$bar" "$C_RST"
}

# ---------------------------------------------------------------- args -----

usage() {
  banner
  cat <<EOF

${C_BLD}Usage:${C_RST} sudo $0 [options]

${C_BLD}Install${C_RST}
  (no options)   interactive wizard — start here
  --check        preflight only, change nothing
  --dry-run, -n  print what would happen instead of doing it
  --yes, -y      non-interactive defaults (never enrolls Secure Boot keys)
  --update       re-sync kernels + regenerate limine.conf
  --uninstall    roll back to GRUB-first

${C_BLD}Secure Boot${C_RST}
  --sb-setup[=mok-shim|custom-db]   sign Limine + enroll your key
  --sb-status                       report Secure Boot state, change nothing
  --sb-resign                       re-enroll conf hash + re-sign EFI files

${C_BLD}Other${C_RST}
  --theme[=name]  install or switch the boot theme
  --help, -h      this text

Docs: README.md and the docs/ folder.
EOF
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
    --theme) MODE="theme"; THEME_METHOD="ask"; shift ;;
    --theme=*) MODE="theme"; THEME_METHOD="${1#--theme=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --dry-run|--dryrun|-n) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1 (see --help)"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- helpers --

confirm() {
  local prompt="${1:-Proceed?}"
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "(dry-run: would ask: $prompt [y/N])"; return 0; fi
  local ans=""
  read -r -p "$(printf '%s?%s %s [y/N] ' "$C_BLD$C_MAG" "$C_RST" "$prompt")" ans || true
  ans="${ans,,}"   # lowercase
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

# ask_with_default — free-text input with a default (used for disk, timeout, etc.)
ask_with_default() {
  local prompt="$1" def="$2" ans=""
  if [[ "$ASSUME_YES" -eq 1 ]]; then echo "$def"; return; fi
  read -r -p "$(printf '%s?%s %s [%s] ' "$C_BLD$C_MAG" "$C_RST" "$prompt" "$def")" ans || true
  echo "${ans:-$def}"
}

# ask_yes_no — yes/no prompt: y/Yes, n/No
# Prints the chosen value ("yes"/"no") to stdout.
ask_yes_no() {
  local prompt="$1" def="${2:-no}" ans=""
  if [[ "$ASSUME_YES" -eq 1 ]]; then echo "yes"; return; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "(dry-run: $prompt -> $def)"; echo "$def"; return; fi
  read -r -p "$(printf '%s?%s %s (y/n) [%s] ' "$C_BLD$C_MAG" "$C_RST" "$prompt" "$def")" ans || true
  ans="${ans,,}"
  if [[ -z "$ans" ]]; then
    echo "$def"
  elif [[ "$ans" == "1" || "$ans" == "y" || "$ans" == "yes" ]]; then
    echo "yes"
  elif [[ "$ans" == "2" || "$ans" == "n" || "$ans" == "no" ]]; then
    echo "no"
  else
    echo "$def"
  fi
}

# ask_numbered — prompt with numbered options.
# Usage: ask_numbered "Prompt" "opt1" "opt2" "opt3" ...
# Prints the 1-based index of the chosen option to stdout.
ask_numbered() {
  local prompt="$1"; shift
  local opts=("$@")
  local i ans
  if [[ "$ASSUME_YES" -eq 1 ]]; then echo "1"; return; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "(dry-run: $prompt -> ${opts[0]})"; echo "1"; return; fi
  section "$prompt" >&2
  i=1
  for o in "${opts[@]}"; do
    printf '  %s%2d)%s %s\n' "$C_CYN$C_BLD" "$i" "$C_RST" "$o" >&2
    ((i++)) || true
  done
  read -r -p "$(printf '%s?%s Choose [1-%d] (Enter = %d) ' "$C_BLD$C_MAG" "$C_RST" "${#opts[@]}" 1)" ans || true
  # Validate: must be a number in range.
  if [[ "$ans" =~ ^[0-9]+$ ]] && [[ "$ans" -ge 1 ]] && [[ "$ans" -le ${#opts[@]} ]]; then
    echo "$ans"
  else
    echo "1"
  fi
}

# limine_version_menu — fetch the 10 newest Limine releases from GitHub,
# show them numbered 1-10, plus option 0 for a custom version.
# Prints the chosen version string (without leading "v") to stdout.
limine_version_menu() {
  local releases=() ver ans idx i
  if [[ "$ASSUME_YES" -eq 1 ]]; then echo "latest"; return; fi
  if [[ "$DRY_RUN" -eq 1 ]]; then echo "(dry-run: limine version -> latest)"; echo "latest"; return; fi
  log "Fetching Limine releases from GitHub..."
  mapfile -t releases < <(curl -fsSL --max-time 15 "https://api.github.com/repos/Limine-Bootloader/Limine/releases?per_page=10" 2>/dev/null \
    | grep -o '"tag_name": *"v[^"]*"' | sed 's/.*"v//;s/"//' || true)
  if [[ ${#releases[@]} -eq 0 ]]; then
    warn "Could not fetch release list — falling back to $LIMINE_FALLBACK_VERSION."
    echo "$LIMINE_FALLBACK_VERSION"
    return
  fi
  section "Limine version" >&2
  printf '  %sAvailable releases (newest first):%s\n' "$C_DIM" "$C_RST" >&2
  i=1
  for ver in "${releases[@]}"; do
    printf '  %s%2d)%s v%s\n' "$C_CYN$C_BLD" "$i" "$C_RST" "$ver" >&2
    ((i++)) || true
  done
  printf '  %s  0)%s Enter a custom version\n' "$C_CYN" "$C_RST" >&2
  read -r -p "$(printf '%s?%s Choose [1-%d or 0 for custom] ' "$C_BLD$C_MAG" "$C_RST" "${#releases[@]}")" ans || true
  ans="${ans,,}"
  if [[ "$ans" == "0" ]]; then
    read -r -p "$(printf '%s?%s Limine version (e.g. 12.9.3) ' "$C_BLD$C_MAG" "$C_RST")" ver || true
    ver="${ver#v}"
    [[ -n "$ver" ]] && echo "$ver" || echo "$LIMINE_FALLBACK_VERSION"
    return
  fi
  if [[ "$ans" =~ ^[0-9]+$ ]] && [[ "$ans" -ge 1 ]] && [[ "$ans" -le ${#releases[@]} ]]; then
    idx=$((ans - 1))
    echo "${releases[$idx]}"
  else
    echo "${releases[0]}"
  fi
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry_print "$*"
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

# Sets SB_STATE (enabled/disabled/unknown) without printing anything.
detect_sb_state() {
  SB_STATE="unknown"
  if secureboot_state | grep -qi enabled; then SB_STATE="enabled"
  elif secureboot_state | grep -qi disabled; then SB_STATE="disabled"
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
  kv "mount" "$esp"
  kv "source" "${src:-unknown}"
  df -h "$esp" 2>/dev/null | tail -n1 | ui_indent || true
  if [[ -n "${src:-}" ]]; then
    disk="$(lsblk -n -o PKNAME "$src" 2>/dev/null | head -n1 || true)"
    part="$(lsblk -n -o PARTN "$src" 2>/dev/null | head -n1 || true)"
    [[ -n "$disk" ]] && kv "disk" "/dev/$disk  part #${part:-?}"
    kv "partuuid" "$(lsblk -n -o PARTUUID "$src" 2>/dev/null | head -n1 || echo ?)"
    kv "fat uuid" "$(lsblk -n -o UUID "$src" 2>/dev/null | head -n1 || echo ?)"
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
  ver="$(curl -fsSL --max-time 15 "$LIMINE_GITHUB_API" 2>/dev/null | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]*"' | head -n1 | sed 's/.*v\([0-9][^"]*\)".*/\1/' || true)"
  [[ -n "$ver" ]] && echo "$ver" || echo "$LIMINE_FALLBACK_VERSION"
}

# ---------------------------------------------------------------- preflight

preflight() {
  banner
  printf '  %sMode:%s %s' "$C_DIM" "$C_RST" "$MODE"
  [[ "$DRY_RUN" -eq 1 ]] && printf '  %s(dry-run)%s' "$C_YLW" "$C_RST"
  [[ "$ASSUME_YES" -eq 1 ]] && printf '  %s(auto-yes)%s' "$C_YLW" "$C_RST"
  printf '\n'

  is_fedora || die "This script is for Fedora only (ID=fedora in /etc/os-release)."

  section "System"
  ok "Fedora detected: $(fedora_version)"

  local fw
  fw="$(firmware_type)"
  if [[ "$fw" == "uefi" ]]; then
    ok "Firmware: UEFI (primary supported path)"
  else
    warn "Firmware: legacy BIOS detected. UEFI is recommended; BIOS install is best-effort."
  fi

  section "Secure Boot"
  detect_sb_state
  kv "firmware" "$(secureboot_state 2>/dev/null | head -n1 || echo unknown)"
  if [[ "$SB_STATE" == "enabled" ]]; then
    warn "Secure Boot is ENABLED. Upstream Limine is NOT Microsoft-signed."
    hint "GRUB keeps working; signing Limine is offered later, opt-in:"
    hint "• mok-shim (recommended) — MOK key + shim chainload, no firmware Setup Mode"
    hint "• custom-db (advanced)   — own DB keys + firmware Setup Mode enrollment"
    hint "Docs: docs/secure-boot.md — or afterwards:  sudo $0 --sb-setup"
  elif [[ "$SB_STATE" == "disabled" ]]; then
    ok "Secure Boot: disabled — Limine boots unsigned, signing stays optional"
    hint "Only needed if you plan to re-enable Secure Boot:  sudo $0 --sb-setup"
  else
    warn "Secure Boot state unknown (mokutil missing?). Continuing; signing stays optional."
  fi

  section "EFI system partition"
  local esp
  esp="$(detect_esp)" || die "Could not find ESP. Expected /boot/efi (vfat). Mount it first."
  esp_details "$esp"
  # fstype check
  local fstype
  fstype="$(findmnt -n -o FSTYPE --target "$esp" 2>/dev/null || echo ?)"
  [[ "$fstype" == "vfat" ]] || warn "ESP fstype is '$fstype' (expected vfat). Continuing, but Limine needs FAT."
  ok "ESP found at $esp"

  section "Space"
  local free need
  free="$(esp_free_mb "$esp")"
  need="$(needed_mb_estimate)"
  kv "ESP free" "${free} MB"
  kv "need (est)" "${need} MB   (all kernels + 60 MB headroom)"
  if [[ "$free" -lt "$need" ]]; then
    warn "ESP may be too small. Options:"
    hint "sudo dnf remove --oldinstallonly         (keep only 2 kernels)"
    hint "set installonly_limit=2 in /etc/dnf/dnf.conf"
    hint "or enlarge the ESP"
    if ! confirm "Continue despite tight ESP space?"; then
      die "Aborted. Free ESP space and re-run."
    fi
  else
    ok "ESP space looks fine."
  fi

  section "Kernels"
  local k
  k="$(list_fedora_kernels)"
  [[ -n "$k" ]] || die "No /boot/vmlinuz-* kernels found. Is this a Fedora install?"
  printf '%s\n' "$k" | while read -r v; do printf '  %s•%s %s\n' "$C_GRY" "$C_RST" "$v"; done
  kv "cmdline" "$(kernel_cmdline)"
  kv "root hint" "$(root_hint)"

  section "Boot entries"
  efi_list | head -n 30 | ui_indent || warn "efibootmgr output unavailable."
  rpm -q grub2-efi-x64 grub2-common shim-x64 grubby 2>/dev/null | ui_indent || true
  if [[ -d /boot/grub2 || -d /boot/efi/EFI/fedora ]]; then
    ok "GRUB/Shim install detected (will be KEPT as fallback)."
  fi

  section "Extras auto-detect"
  local rootfs
  rootfs="$(findmnt -n -o FSTYPE / 2>/dev/null || echo ?)"
  kv "root fs" "$rootfs"
  if [[ "$rootfs" == "btrfs" ]]; then
    hint "BTRFS detected: snapshot boot entries are available (optional)."
  else
    hint "Not BTRFS ($rootfs): snapshot entries will be skipped."
  fi
  if command -v os-prober >/dev/null 2>&1; then hint "os-prober present"; else hint "os-prober not installed (Windows scan optional)"; fi
  if [[ -d /boot/efi/EFI/Microsoft ]]; then hint "Windows ESP dir detected"; else hint "No Windows ESP dir seen"; fi

  nvidia_preflight_report || true

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
    dry_print "dnf install -y ${pkgs[*]} ${opt_pkgs[*]}"
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
  printf '  %sURL: %s%s\n' "$C_DIM" "$url" "$C_RST"
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "curl -> $work/limine-binary.tar.xz"; return 0; fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "mkdir + cp $src/BOOTX64.EFI -> $dest_dir/limine_x64.efi (+ fallback)"; return 0; fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "cp limine-bios.sys + limine bios-install"; return 0; fi
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

# Returns 0 if config file contains only comments, blanks, and KEY="value" assignments.
# Any stray line (e.g. leftover help text like "--reset") makes it invalid.
config_is_valid() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  if grep -vE '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$f" 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

write_default_config() {
  log "Writing $CONFIG_FILE (CachyOS-style knobs, Fedora defaults)..."
  if [[ -f "$CONFIG_FILE" && "$ASSUME_YES" -eq 0 && "$MODE" == "install" ]]; then
    if config_is_valid "$CONFIG_FILE"; then
      warn "$CONFIG_FILE already exists — keeping it (delete to regenerate defaults)."
      return 0
    else
      warn "$CONFIG_FILE exists but is malformed — regenerating defaults automatically."
    fi
  fi
  local cmdline root osname timeout fb eb db ss sbm enroll verify ck themeid
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
  ck="no"; [[ "${DO_CACHYOS:-no}" == "yes" ]] && ck="yes"
  themeid="${DO_THEME_ID:-catppuccin-mocha}"
  theme_valid "$themeid" || themeid="catppuccin-mocha"
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "write $CONFIG_FILE"; return 0; fi
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

# Boot theme (managed by the installer; switch anytime: sudo fedora-limine-switch.sh --theme).
# Catalog: catppuccin-mocha|latte|frappe|macchiato, tokyo-night, nord,
# rose-pine, cachyos, fallout, fallout-alt, lumon, thinkpad, j0x, sekiro,
# shiro, synthwave, apex, spitfire, arch, squatchware, scary-cat, none. The snippet at THEME_SNIPPET is
# emitted into limine.conf on every regen (none = generator defaults).
THEME_NAME="$themeid"
THEME_SNIPPET="$THEME_SNIPPET"

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

# Bake b2sum(limine.conf) into the EFI binaries via 'limine enroll-config'
# (explicit opt-in to SB hardening; re-enrolled + re-signed on every sync).
ENABLE_ENROLL_CONFIG="$enroll"

# Auto-sign CachyOS (COPR) kernels with the SB MOK key on every sync/update.
# COPR CachyOS kernels are unsigned and will NOT boot under Secure Boot.
ENABLE_CACHYOS_SIGN="$ck"

# Sort wildcard BOOT_ORDER entries alphabetically? (CachyOS ENABLE_SORT; default
# no = newest kernel first via sort -Vr, which suits Fedora kernel updates.)
ENABLE_SORT="no"

# Skip UEFI NVRAM registration even on UEFI (CachyOS SKIP_UEFI; for broken
# firmware, e.g. some MSI boards: use the fallback path + set boot order in setup).
SKIP_UEFI="no"

# Where limine-install puts the NVRAM entry when (re)created: first | last | keep.
# first = Limine first (GRUB kept as fallback); last/keep leave the default alone.
UEFI_BOOT_ORDER="first"

# Fallback-entry cmdline override (CachyOS KERNEL_CMDLINE[fallback]). Empty =
# reuse KERNEL_CMDLINE (rescue entries still append 'single nomodeset').
KERNEL_CMDLINE_FALLBACK=""

# Per-kernel cmdline overrides (CachyOS KERNEL_CMDLINE[<name>]): export
# KERNEL_CMDLINE_<sanitized-version>="..." where dots/dashes become underscores,
# e.g. KERNEL_CMDLINE_6_15_9_200_fc43_x86_64="...". Empty = use KERNEL_CMDLINE.
# (Drop-in files in /etc/limine/entry-tool.d/*.conf are sourced the same way.)

# Backup limine.conf before rewriting, at most every N hours (CachyOS
# CONFIG_BACKUP_THRESHOLD; 0 = every run).
CONFIG_BACKUP_THRESHOLD="6"

# Stop adding snapshot entries once ESP usage reaches N% (CachyOS parity).
LIMIT_USAGE_PERCENT="85"

# Comma-separated globs of snapshot types / entry names to exclude from
# snapshot boot entries (CachyOS EXCLUDE_SNAPSHOT_TYPES/ENTRIES).
EXCLUDE_SNAPSHOT_TYPES="pre, post"
EXCLUDE_SNAPSHOT_ENTRIES="Windows*, windows*, *fallback"

# Extra kernel parameters appended to snapshot entries only
# (CachyOS SNAPSHOT_KERNEL_PARAMETERS+=...; e.g. systemd.volatile=overlay).
SNAPSHOT_KERNEL_PARAMETERS=""
EOF
  ok "$CONFIG_FILE written. Edit KERNEL_CMDLINE/TIMEOUT there anytime, then: sudo limine-update"
}

# ---------------------------------------------------------------- hook + sync

install_hook_and_sync_script() {
  log "Installing kernel-install hook + sync generator (Fedora equivalent of CachyOS pacman hooks)..."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry_print "write $SYNC_SCRIPT, $UPDATE_WRAPPER, $HOOK_FILE + /etc/limine/hooks/{pre,post}.d defaults"
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
ENABLE_SORT="no"; SKIP_UEFI="no"; UEFI_BOOT_ORDER="first"
KERNEL_CMDLINE_FALLBACK=""; CONFIG_BACKUP_THRESHOLD="6"
LIMIT_USAGE_PERCENT="85"; EXCLUDE_SNAPSHOT_TYPES="pre, post"
EXCLUDE_SNAPSHOT_ENTRIES="Windows*, windows*"; SNAPSHOT_KERNEL_PARAMETERS=""
HOOK_BASE="${HOOK_BASE:-/etc/limine/hooks}"
THEME_NAME="catppuccin-mocha"; THEME_SNIPPET="/etc/limine/theme.conf"
LIMINE_TOOL="/usr/local/bin/limine"
# shellcheck disable=SC1090
# Source only comment / assignment / blank lines. A mangled config
# (e.g. leftover help text like "--reset") must never abort the sync
# under `set -e` — kernel-install hooks must not break on a bad config.
[[ -f "$CONFIG" ]] && . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$CONFIG" 2>/dev/null || true)
# CachyOS-style drop-ins. Priority (like limine-entry-tool): drop-ins first,
# /etc/default/limine last so it always wins. Re-source CONFIG after drop-ins.
for _dropin in /etc/limine/entry-tool.d/*.conf; do
  [[ -f "$_dropin" ]] && . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$_dropin" 2>/dev/null || true)
done
unset _dropin
[[ -f "$CONFIG" ]] && . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$CONFIG" 2>/dev/null || true)
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
  # Sign CachyOS kernels on ESP if SB signing is enabled (COPR kernels are unsigned).
  if [[ "${ENABLE_CACHYOS_SIGN:-no}" == "yes" && "$ver" == *"cachyos"* ]]; then
    local kdir="${SB_KEY_DIR:-/etc/limine/keys}"
    if [[ -f "$kdir/MOK.priv" && -f "$kdir/MOK.pem" && -x "$(command -v sbsign 2>/dev/null || true)" ]]; then
      local tmp
      tmp="$(mktemp /tmp/limine-cachyos-esp-sign-XXXXXX)"
      if sbsign --key "$kdir/MOK.priv" --cert "$kdir/MOK.pem" --output "$tmp" "$dest/vmlinuz-$ver" 2>/dev/null; then
        mv "$tmp" "$dest/vmlinuz-$ver"
        echo "  signed CachyOS kernel on ESP: $ver"
      else
        rm -f "$tmp"
        echo "  WARN: sbsign failed for CachyOS kernel $ver on ESP" >&2
      fi
      command -v restorecon >/dev/null 2>&1 && restorecon "$dest/vmlinuz-$ver" 2>/dev/null || true
    else
      echo "  WARN: CachyOS kernel $ver not signed on ESP (SB keys or sbsign missing)" >&2
    fi
  fi
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

limine_mutex_lock() {
  # CachyOS parity: atomic mutex against concurrent ESP writers (kernel-install
  # hook vs snapper plugin vs manual runs). Never fatal: warn + continue.
  mkdir -p /run/lock 2>/dev/null || return 0
  exec 200>/run/lock/limine-fedora-sync.lock 2>/dev/null || return 0
  flock --timeout=10 200 2>/dev/null || echo "  WARN: ESP mutex timeout, continuing" >&2
}

run_boot_hooks() {
  # CachyOS /etc/boot/hooks parity (Fedora path: /etc/limine/hooks).
  # Executables in $HOOK_BASE/pre.d run before work, post.d after conf regen.
  # Env: HOOK_CALLER (this script name) + HOOK_CMDLINE (full argv).
  # Exit codes: 0 ok, 1-99 warn+continue, >=100 fatal (stop + propagate).
  local dir="$1" hook rc=0
  export HOOK_CALLER="limine-fedora-sync"
  export HOOK_CMDLINE="limine-fedora-sync $*"
  for hook in "$HOOK_BASE/$dir.d"/*; do
    [[ -f "$hook" && -x "$hook" && "$hook" != *.disabled ]] || continue
    rc=0
    "$hook" || rc=$?
    ((rc == 0)) && continue
    if ((rc >= 100)); then
      echo "  ERROR: $dir hook fatal (exit $rc): $hook" >&2
      return "$rc"
    else
      echo "  WARN: $dir hook failed (exit $rc): $hook" >&2
    fi
  done
  return 0
}

backup_conf() {
  # CachyOS CONFIG_BACKUP_THRESHOLD parity: snapshot limine.conf before
  # rewriting, at most every N hours (0 = every run).
  [[ -f "$ESP/limine.conf" ]] || return 0
  local thresh="${CONFIG_BACKUP_THRESHOLD:-6}" old="$ESP/limine.conf.old"
  [[ "$thresh" =~ ^[0-9]+$ ]] || thresh=6
  if [[ -f "$old" && "$thresh" -gt 0 ]]; then
    local age_now age_old
    age_now="$(date +%s)"
    age_old="$(stat -c %Y "$old" 2>/dev/null || echo 0)"
    (( age_now - age_old < thresh * 3600 )) && return 0
  fi
  cp -v "$ESP/limine.conf" "$old" 2>/dev/null || true
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
    if [[ -n "${THEME_SNIPPET:-}" && -f "${THEME_SNIPPET:-}" ]]; then
      # Theme owns all visuals: emit its snippet (generator-owned keys were
      # filtered at install time). Under verification, append #b2sum to
      # hashless wallpaper:/term_font: boot(): paths so SB hash enforcement
      # accepts them (same rule as kernels/initramfs).
      local tline tstrip rel
      while IFS= read -r tline || [[ -n "$tline" ]]; do
        tstrip="$(echo "$tline" | sed -e 's/^[[:space:]]*//')"
        case "$tstrip" in
          ""|\#*) echo "$tline" ;;
          wallpaper:*|term_font:*)
            if [[ "$VERIFY_ON" == "yes" && "$tline" == *"boot():/"* && "$tline" != *"#"* ]]; then
              rel="$(echo "$tline" | sed -n 's|.*boot():/\([^ #]*\).*|\1|p')"
              if [[ -n "$rel" && -f "$ESP/$rel" ]]; then
                echo "${tline}#$(b2sum "$ESP/$rel" | cut -d' ' -f1)"
              else
                echo "$tline"
              fi
            else
              echo "$tline"
            fi ;;
          *) echo "$tline" ;;
        esac
      done < "$THEME_SNIPPET"
    else
      echo "term_palette: ${TERM_PALETTE}"
      echo "term_palette_bright: ${TERM_PALETTE_BRIGHT}"
      echo "term_background: ${TERM_BACKGROUND}"
      echo "term_foreground: ${TERM_FOREGROUND}"
      [[ -n "$wallpaper_line" ]] && echo "$wallpaper_line"
    fi
    echo ""
    echo "/${TARGET_OS_NAME}"
    # Normal kernels, newest first.
    local vers v printed=0
    vers="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v '^0-rescue' | sort -Vr || true)"
    if [[ "${ENABLE_SORT:-no}" == "yes" ]]; then
      vers="$(echo "$vers" | sort -V || true)"  # CachyOS ENABLE_SORT: alphabetical
    fi
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
      # CachyOS KERNEL_CMDLINE[fallback] / KERNEL_CMDLINE[<name>] parity:
      # fallback entries use KERNEL_CMDLINE_FALLBACK when set; any version can
      # be overridden via KERNEL_CMDLINE_<sanitized-ver> (dots/dashes -> _).
      if [[ "$v" == *fallback* && -n "${KERNEL_CMDLINE_FALLBACK:-}" ]]; then cmd="$KERNEL_CMDLINE_FALLBACK"; fi
      _san="${v//[^A-Za-z0-9]/_}"; _override="KERNEL_CMDLINE_$_san"
      local _kcmd_ref="$_override"
      [[ -n "${!_kcmd_ref:-}" ]] && cmd="${!_kcmd_ref}"
      unset _san _override _kcmd_ref
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
    limine_mutex_lock
    run_boot_hooks pre "$@" || exit 2
    if [[ "${2:-}" != "" && "${2:-}" != "all" ]]; then
      sync_one "$2"   # single-version fast path from kernel-install hook
    else
      for v in $(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v '^0-rescue' | sort -Vr); do
        sync_one "$v"
      done
      prune_stale
    fi
    # Sanity: meta-package present but no payload is the classic "CachyOS
    # kernel not in the menu" cause (kernel-cachyos is tiny; vmlinuz is in -core).
    if rpm -q kernel-cachyos-core >/dev/null 2>&1 && ! ls /boot/vmlinuz-*cachyos* >/dev/null 2>&1; then
      echo "  WARN: kernel-cachyos-core installed but no /boot/vmlinuz-*cachyos*." >&2
      echo "  WARN: run: sudo dnf reinstall -y kernel-cachyos-core kernel-cachyos-modules" >&2
    fi
    backup_conf
    gen_conf
    run_boot_hooks post "$@" || exit 3
    ;;
  remove)
    limine_mutex_lock
    run_boot_hooks pre "$@" || exit 2
    ver="${2:-}"; [[ -n "$ver" ]] && rm -rf "$KERNEL_DIR_BASE/$ver"
    backup_conf
    gen_conf
    run_boot_hooks post "$@" || exit 3
    ;;
  conf-only|config)
    limine_mutex_lock
    run_boot_hooks pre "$@" || exit 2
    backup_conf
    gen_conf
    run_boot_hooks post "$@" || exit 3
    ;;
  scan)
    # CachyOS `limine-scan` parity: report EFI loaders + NVRAM entries that
    # FIND_BOOTLOADERS would turn into chainload entries (read-only).
    echo "ESP: $ESP"
    echo "-- EFI loaders on ESP --"
    find "$ESP" -iname '*.efi' 2>/dev/null | sort || true
    echo "-- NVRAM boot entries --"
    efibootmgr -v 2>/dev/null || echo "(efibootmgr unavailable)"
    ;;
  list)
    # CachyOS `limine-list` parity: entry tree of the generated limine.conf.
    [[ -f "$ESP/limine.conf" ]] || { echo "no $ESP/limine.conf (run sync first)" >&2; exit 1; }
    grep -E '^/|^[[:space:]]+//' "$ESP/limine.conf" \
      | sed -e 's|^/|/ |' -e 's|^    //|  - |' || true
    ;;
  *)
    echo "Usage: $0 [sync [VERSION|all]|remove VERSION|conf-only|scan|list]"; exit 2 ;;
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

  # ---- boot hooks dir (CachyOS /etc/boot/hooks parity; Fedora: /etc/limine/hooks)
  # Executables in pre.d run before every sync, post.d after conf regen.
  # HOOK_CALLER + HOOK_CMDLINE are exported; exit 0 ok, 1-99 warn, >=100 fatal.
  # A .disabled suffix turns a hook off.
  mkdir -p /etc/limine/hooks/pre.d /etc/limine/hooks/post.d /etc/limine/entry-tool.d
  if [[ ! -f /etc/limine/hooks/post.d/89-warn-missing-file-hashes ]]; then
    cat > /etc/limine/hooks/post.d/89-warn-missing-file-hashes <<'HASHHOOK_EOF'
#!/usr/bin/env bash
# 89-warn-missing-file-hashes — CachyOS parity post hook.
# Warns when Secure Boot is on but per-file BLAKE2 hashes are off (Limine
# panics on hashless linux paths once a conf hash is enrolled).
set -u
cfg="/etc/default/limine"
sb="no"; verify="no"
[[ -f "$cfg" ]] && sb="$(grep -E '^[[:space:]]*SECURE_BOOT=' "$cfg" 2>/dev/null | tail -n1 | cut -d'"' -f2 || true)"
[[ -f "$cfg" ]] && verify="$(grep -E '^[[:space:]]*ENABLE_VERIFICATION=' "$cfg" 2>/dev/null | tail -n1 | cut -d'"' -f2 || true)"
if [[ "$sb" != "no" && "$verify" != "yes" ]]; then
  echo "limine hook $0: WARNING: SECURE_BOOT=$sb but ENABLE_VERIFICATION!=yes." >&2
  echo "  Run: sudo $0 --sb-resign (or set ENABLE_VERIFICATION=yes + limine-update)." >&2
  exit 1
fi
exit 0
HASHHOOK_EOF
    chmod +x /etc/limine/hooks/post.d/89-warn-missing-file-hashes
  fi
  if [[ ! -f /etc/limine/hooks/post.d/91-example-esp-set-ro.disabled ]]; then
    cat > /etc/limine/hooks/post.d/91-example-esp-set-ro.disabled <<'ROHOOK_EOF'
#!/usr/bin/env bash
# Example (disabled): remount the ESP read-only after each sync to prevent
# accidental recursive writes. Enable: remove the .disabled suffix.
set -u
esp="$(grep -E '^[[:space:]]*ESP_PATH=' /etc/default/limine 2>/dev/null | tail -n1 | cut -d'"' -f2 || true)"
[[ -n "${esp:-}" ]] && mount -o remount,ro "$esp" 2>/dev/null || true
exit 0
ROHOOK_EOF
    chmod +x /etc/limine/hooks/post.d/91-example-esp-set-ro.disabled
  fi
  if [[ ! -f /etc/limine/hooks/pre.d/05-example-esp-set-rw.disabled ]]; then
    cat > /etc/limine/hooks/pre.d/05-example-esp-set-rw.disabled <<'RWHOOK_EOF'
#!/usr/bin/env bash
# Example (disabled): remount the ESP read-write before each sync (pairs with
# 91-example-esp-set-ro). Enable: remove the .disabled suffix.
set -u
esp="$(grep -E '^[[:space:]]*ESP_PATH=' /etc/default/limine 2>/dev/null | tail -n1 | cut -d'"' -f2 || true)"
[[ -n "${esp:-}" ]] && mount -o remount,rw "$esp" 2>/dev/null || true
exit 0
RWHOOK_EOF
    chmod +x /etc/limine/hooks/pre.d/05-example-esp-set-rw.disabled
  fi

  ok "Hook + sync scripts installed:"
  hint "$HOOK_FILE"
  hint "$SYNC_SCRIPT"
  hint "$UPDATE_WRAPPER  (run this after editing $CONFIG_FILE)"
  hint "/etc/limine/hooks/{pre,post}.d  (CachyOS-style boot hooks)"
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
  # CachyOS SKIP_UEFI parity: broken firmware -> fallback path only, boot order
  # set manually in firmware setup.
  if grep -Eq '^[[:space:]]*SKIP_UEFI="yes"' "$CONFIG_FILE" 2>/dev/null; then
    warn "SKIP_UEFI=yes: skipping NVRAM registration (fallback EFI/BOOT/BOOTX64.EFI is the boot path)."
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
    dry_print "efibootmgr -c -d $esp_disk -p $esp_part -L \"$label\" -l '$loader'"
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
  section "Current boot entries"
  efi_list | ui_indent || true
  # CachyOS UEFI_BOOT_ORDER parity: first = Limine first (GRUB kept as fallback);
  # last/keep = register only, leave the current default boot option alone.
  local _order_policy="first"
  _order_policy="$(grep -E '^[[:space:]]*UEFI_BOOT_ORDER=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d'"' -f2 || true)"
  [[ -n "${_order_policy:-}" ]] || _order_policy="first"
  if [[ "$_order_policy" == "last" || "$_order_policy" == "keep" ]]; then
    log "UEFI_BOOT_ORDER=$_order_policy: leaving BootOrder untouched."
    ok "NVRAM entry registered. Old 'Fedora' (GRUB/shim) entry kept for rollback."
    return 0
  fi
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
    # Auto-heal a config mangled by the old backtick bug (usage text like
    # "--reset" leaked into the file): keep only comment/assignment/blank
    # lines, preserving all real settings.
    if ! config_is_valid "$CONFIG_FILE"; then
      cp -a "$CONFIG_FILE" "$CONFIG_FILE.mangled-bak-$(date +%F-%H%M%S)" 2>/dev/null || true
      grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp" || true
      # Fix the one mangled comment line, if present.
      sed -i "s|.*via usage: limine enroll-config.*|# Bake b2sum(limine.conf) into the EFI binaries via 'limine enroll-config'|" "$CONFIG_FILE.tmp" 2>/dev/null || true
      cat "$CONFIG_FILE.tmp" > "$CONFIG_FILE" 2>/dev/null && \
        warn "Repaired mangled $CONFIG_FILE (backup kept; re-run if needed)." || \
        warn "$CONFIG_FILE is malformed (could not auto-repair; delete to regenerate)."
      rm -f "$CONFIG_FILE.tmp" 2>/dev/null || true
    fi
    # Source only comment / assignment / blank lines (same filter as the sync
    # script). A mangled config must never execute stray lines like "--reset".
    # shellcheck disable=SC1091
    . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$CONFIG_FILE" 2>/dev/null || true) || true
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
  local need=(openssl mokutil sbsign sbverify sbattach b2sum)
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "dnf install -y sbsigntools openssl mokutil efitools"; return 0; fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "openssl req + x509 der"; return 0; fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "sbsign $efi + sbverify"; return 0; fi
  command -v sbsign >/dev/null 2>&1 || { warn "sbsign missing (skipping $efi)"; return 0; }
  # Strip ALL stale signatures first. Re-signing an already-signed binary makes
  # sbsign APPEND ("Image was already signed") and sbverify then fails on the
  # stale signature whose hash no longer matches the re-enrolled binary.
  # sbattach --remove defaults to the FIRST signature only, and repeated runs
  # of the old script stacked several — so loop until no signature table is
  # left. This drops signatures but keeps the enrolled conf hash.
  if command -v sbattach >/dev/null 2>&1; then
    local _stripped=0
    while run sbattach --remove "$efi" 2>/dev/null; do
      _stripped=$((_stripped + 1))
    done || true
  else
    warn "sbattach missing (sbsigntools) — resign may append a 2nd signature and fail sbverify"
  fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "b2sum conf -> enroll-config + sbsign each managed EFI"; return 0; fi
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
  sb_publish_keys_to_esp "$esp" "$dir"
  ok "Enrolled + signed $n EFI(s)."
}

sb_publish_keys_to_esp() {
  # Publish the PUBLIC key (MOK.der + MOK.pem) to $ESP/EFI/limine/keys/ so it
  # is visible/findable from the ESP. MOK.priv is NEVER copied (stays 600 in
  # /etc/limine/keys). Public certs are harmless on FAT; enrollment still goes
  # through mokutil/NVRAM, this copy is for convenience + verification.
  local esp="$1" dir="${2:-$SB_KEY_DIR_DEFAULT}"
  [[ -f "$dir/MOK.der" && -f "$dir/MOK.pem" ]] || { warn "no public key in $dir (skipping ESP publish)"; return 0; }
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "publish MOK.{der,pem} -> $esp/EFI/limine/keys/"; return 0; fi
  mkdir -p "$esp/EFI/limine/keys" 2>/dev/null || { warn "cannot create $esp/EFI/limine/keys"; return 0; }
  run cp -f "$dir/MOK.der" "$esp/EFI/limine/keys/MOK.der" || warn "could not publish MOK.der to ESP"
  run cp -f "$dir/MOK.pem" "$esp/EFI/limine/keys/MOK.pem" || warn "could not publish MOK.pem to ESP"
  chmod 644 "$esp/EFI/limine/keys/MOK.der" "$esp/EFI/limine/keys/MOK.pem" 2>/dev/null || true
  command -v restorecon >/dev/null 2>&1 && restorecon "$esp/EFI/limine/keys/MOK.der" "$esp/EFI/limine/keys/MOK.pem" 2>/dev/null || true
  ok "Public key published: $esp/EFI/limine/keys/MOK.{der,pem} (private key stays in $dir)"
}

sb_set_config() {
  # Idempotently set SECURE_BOOT / ENABLE_VERIFICATION / ENABLE_ENROLL_CONFIG.
  local method="$1"
  [[ -f "$CONFIG_FILE" ]] || die "No $CONFIG_FILE (run install first)."
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "set SECURE_BOOT=$method + verification/enroll yes in $CONFIG_FILE"; return 0; fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "backup $grub -> .grub-bak; copy signed $src -> $grub"; return 0; fi
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "restore $bak -> $grub"; return 0; fi
  run cp -v "$bak" "$grub"
  ok "GRUB restored from backup. (Removing $bak? Keeping it is safer — delete manually.)"
}

sb_print_mok_instructions() {
  local dir="${1:-$SB_KEY_DIR_DEFAULT}"
  section "MOK enrollment — one reboot required"
  cat <<EOF
  Boot order is now: 'Fedora' (shim) first, 'Limine' second (set automatically).
  1. Reboot. Firmware loads shim -> the blue MokManager screen appears.
     (If firmware boots Limine directly instead, use the firmware boot menu
      key and pick 'Fedora' — MokManager only runs via shim.)
     Choose: Enroll MOK -> Continue -> Yes -> enter the password you just set
     -> Reboot.
  2. If no MokManager appears, you booted the direct Limine entry: with SB on
     firmware rejects it until the MOK is enrolled (expected). Reboot and
     pick 'Fedora'.
  3. If you missed it: re-run  sudo mokutil --import $dir/MOK.der
     (If it says "already in the enrollment request", your FIRST password
      still applies. Forgot it? sudo mokutil --reset, reboot, then re-run
      sudo $0 --sb-setup=mok-shim to queue a fresh request.)
  4. Verify after reboot:  mokutil --list-enrolled | grep -i limine
                           sbverify --cert $dir/MOK.pem /boot/efi/EFI/limine/limine_x64.efi
  Boot path with SB on: firmware -> shimx64.efi (MS-signed) -> grubx64.efi
  ( = signed Limine, MOK-verified) -> Fedora kernels (hash-verified by Limine).
  Direct 'Limine' NVRAM entry boots only with SB off (or custom-db enrolled).
EOF
}

sb_prefer_shim_first() {
  # mok-shim: the next boot MUST reach shim (MokManager + chainload).
  # Limine-first + SB on + MOK not yet enrolled = firmware rejects Limine
  # immediately and MokManager never runs (worse with Timeout: 0, no menu).
  local esp="${1:-/boot/efi}"
  local fedora_num limine_num order rest neworder
  fedora_num="$(efibootmgr 2>/dev/null | grep -i 'fedora' | head -n1 | grep -o '[0-9A-Fa-f]\{4\}' | head -n1 || true)"
  limine_num="$(efibootmgr 2>/dev/null | grep -i 'limine' | head -n1 | grep -o '[0-9A-Fa-f]\{4\}' | head -n1 || true)"
  [[ -n "${fedora_num:-}" ]] || { warn "No 'Fedora' NVRAM entry found (cannot prefer shim first)."; return 0; }
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "efibootmgr -o $fedora_num,[limine,]... (shim first)"; return 0; fi
  order="$(efibootmgr 2>/dev/null | grep '^BootOrder:' | awk '{print $2}' || true)"
  rest="$(echo "$order" | tr ',' '\n' | grep -vi "^$fedora_num\$" | grep -vi "^${limine_num:-XXXX}\$" | paste -sd, - || true)"
  neworder="$fedora_num"
  [[ -n "${limine_num:-}" ]] && neworder="$neworder,$limine_num"
  [[ -n "${rest:-}" ]] && neworder="$neworder,$rest"
  log "Setting BootOrder: $neworder (shim/Fedora first for MOK enrollment; Limine kept second)"
  efibootmgr -o "$neworder" || warn "Could not set BootOrder (set it manually in firmware)."
}

sb_print_db_guide() {
  local dir="${1:-$SB_KEY_DIR_DEFAULT}"
  section "custom-db method — firmware Setup Mode required (advanced)"
  cat <<EOF
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
  section "Secure Boot status"
  kv "firmware" "$(secureboot_state | head -n1)"
  kv "config" "SECURE_BOOT=$SB_MODE verify=$SB_VERIFY enroll=$SB_ENROLL keys=$SB_KEYS"
  kv "keys" "$(sb_keys_present "$SB_KEYS" && echo "present ($SB_KEYS/MOK.{priv,pem,der})" || echo "MISSING")"
  kv "tool" "$(command -v "$LIMINE_TOOL" >/dev/null 2>&1 && echo "$LIMINE_TOOL" || echo "MISSING ($LIMINE_TOOL)")"
  kv "ESP" "$esp"
  local efi efi_files=()
  mapfile -t efi_files < <(sb_managed_efis "$esp")
  if [[ ${#efi_files[@]} -gt 0 ]]; then
    subhead "Managed EFI files"
    for efi in "${efi_files[@]}"; do
      [[ -n "$efi" ]] || continue
      printf '  %s%s%s\n' "$C_GRY" "$efi" "$C_RST"
      if command -v sbverify >/dev/null 2>&1 && sb_keys_present "$SB_KEYS"; then
        if sbverify --cert "$SB_KEYS/MOK.pem" "$efi" >/dev/null 2>&1; then
          printf '    %s signature:%s VALID (our key)\n' "$C_GRN" "$C_RST"
        else
          printf '    %s signature:%s NOT ours / unsigned\n' "$C_YLW" "$C_RST"
        fi
      fi
    done
  fi
  subhead "Config"
  if [[ -f "$esp/limine.conf" ]]; then
    kv "b2sum" "$(b2sum "$esp/limine.conf" | cut -d' ' -f1 | cut -c1-32)… (full in log)"
    kv "hashed paths" "$(grep -c '#[0-9a-fA-F]\{64,\}' "$esp/limine.conf" 2>/dev/null || echo 0)"
  else
    kv "conf" "MISSING ($esp/limine.conf)"
  fi
  if [[ -f "$esp/EFI/fedora/grubx64.efi.grub-bak" ]]; then
    kv "shim" "GRUB backup present (mok-shim copy active or was active)"
  fi
  if command -v mokutil >/dev/null 2>&1 && sb_keys_present "$SB_KEYS"; then
    subhead "Enrollment"
    local mok_out
    mok_out="$(mokutil --test-key "$SB_KEYS/MOK.der" 2>&1 || true)"
    if echo "$mok_out" | grep -q "is enrolled"; then
      kv "mok" "ENROLLED (firmware trusts our key)"
    elif echo "$mok_out" | grep -q "is not enrolled"; then
      if mokutil --list-new 2>/dev/null | grep -qiE 'certificate|issuer'; then
        kv "mok" "PENDING (reboot via the 'Fedora'/shim entry to finish in MokManager)"
      else
        kv "mok" "NOT enrolled (run --sb-setup=mok-shim, then reboot via shim)"
      fi
    else
      kv "mok" "unknown (mokutil output unclear)"
    fi
    if [[ -f "$esp/EFI/limine/keys/MOK.der" ]]; then
      kv "mok-esp" "published ($esp/EFI/limine/keys/MOK.{der,pem})"
    else
      kv "mok-esp" "not published (re-run --sb-resign)"
    fi
  fi
  nvidia_detect
  if [[ "$NVIDIA_PRESENT" -eq 1 ]]; then
    subhead "NVIDIA"
    kv "driver" "$NVIDIA_SRC ${NVIDIA_VER:-} (signer: ${NVIDIA_SIGNER:-?}, key enrolled: $NVIDIA_ENROLLED)"
    if [[ "$NVIDIA_SRC" == "dkms" ]]; then
      local dkms_cn
      dkms_cn="$(grep '^mok_certificate=' "$DKMS_CONF" 2>/dev/null | cut -d'"' -f2 || true)"
      kv "dkms key" "${dkms_cn:-default /var/lib/dkms/mok.pub}"
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
  # mok-shim safety net: if our MOK is still not enrolled, the next boot must
  # reach shim (MokManager only runs via shim). Direct Limine-first + SB on
  # would reject before MokManager appears.
  if [[ "${SB_MODE:-no}" == "mok-shim" ]] && command -v mokutil >/dev/null 2>&1 \
      && sb_keys_present "$SB_KEYS" \
      && mokutil --test-key "$SB_KEYS/MOK.der" 2>&1 | grep -q "is not enrolled"; then
    sb_prefer_shim_first "$esp"
    warn "MOK not yet enrolled — BootOrder set to shim/Fedora first. Complete MokManager, then re-run --sb-status."
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
  cachyos_menu
  if [[ "${DO_CACHYOS:-no}" == "yes" ]]; then
    if grep -q '^ENABLE_CACHYOS_SIGN=' "$CONFIG_FILE" 2>/dev/null; then
      run sed -i 's|^ENABLE_CACHYOS_SIGN=.*|ENABLE_CACHYOS_SIGN="yes"|' "$CONFIG_FILE"
    else
      echo 'ENABLE_CACHYOS_SIGN="yes"' >> "$CONFIG_FILE"
    fi
    cachyos_sign_all "$SB_KEYS"
    cachyos_hook_install
  fi
  log "Re-syncing kernels with file hashes..."
  run "$SYNC_SCRIPT" sync all
  sb_enroll_and_sign "$esp" "$SB_KEYS"
  sb_deploy_shim_copy "$esp"
  # The shim copy must be signed too (it was copied AFTER signing src — same
  # bytes, signature intact — but re-sign explicitly for certainty).
  sb_sign_file "$esp/EFI/fedora/grubx64.efi" "$SB_KEYS"
  # mok-shim: next boot must reach shim (MokManager only runs via shim).
  sb_prefer_shim_first "$esp"
  echo
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry_print "mokutil --import $SB_KEYS/MOK.der"
  elif [[ "$ASSUME_YES" -eq 1 ]]; then
    warn "--yes: skipping mokutil --import (needs a password + reboot). Run manually:"
    hint "sudo mokutil --import $SB_KEYS/MOK.der"
  else
    subhead "Set a MOK password (you will enter it ONCE in MokManager on next boot):"
    local import_out
    import_out="$(run mokutil --import "$SB_KEYS/MOK.der" 2>&1 || true)"
    printf '%s\n' "$import_out" | ui_indent
    if echo "$import_out" | grep -qi "already in the enrollment request"; then
      warn "MOK.der was already queued by an earlier run — your FIRST password still applies."
      warn "Forgot it? sudo mokutil --reset, reboot, then re-run: sudo $0 --sb-setup=mok-shim"
    elif echo "$import_out" | grep -qi "failed\|error\|command not found"; then
      warn "mokutil --import failed (no efivars? re-run where ESP/firmware NVRAM exists)."
    fi
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
  cachyos_menu
  if [[ "${DO_CACHYOS:-no}" == "yes" ]]; then
    if grep -q '^ENABLE_CACHYOS_SIGN=' "$CONFIG_FILE" 2>/dev/null; then
      run sed -i 's|^ENABLE_CACHYOS_SIGN=.*|ENABLE_CACHYOS_SIGN="yes"|' "$CONFIG_FILE"
    else
      echo 'ENABLE_CACHYOS_SIGN="yes"' >> "$CONFIG_FILE"
    fi
    cachyos_sign_all "$SB_KEYS"
    cachyos_hook_install
  fi
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
      local mc
      mc="$(ask_numbered "Secure Boot setup — pick a method" \
        "mok-shim — MOK key + shim chainload, no firmware Setup Mode (recommended)" \
        "custom-db — enroll key into firmware db in Setup Mode, no shim (advanced)" \
        "no — cancel")"
      case "$mc" in
        1) method="mok-shim" ;;
        2) method="custom-db" ;;
        3) method="no" ;;
        *) method="no" ;;
      esac
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
  # Preserves a pre-seeded method from the CachyOS kernel flow (no double-ask).
  if [[ "${DO_SECUREBOOT:-no}" == "mok-shim" || "${DO_SECUREBOOT:-no}" == "custom-db" ]]; then
    section "Secure Boot"
    kv "method" "$DO_SECUREBOOT (already chosen in CachyOS kernel setup)"
    return 0
  fi
  section "Secure Boot"
  echo "  Firmware reports: $SB_STATE. Unsigned Limine boots only with SB off."
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
  local choice
  choice="$(ask_numbered "Secure Boot method" "no (unsigned — Limine only boots with SB off)" "mok-shim (sign + MOK enroll, recommended)" "custom-db (sign + firmware-db enrollment, advanced)")"
  case "$choice" in
    1) DO_SECUREBOOT="no" ;;
    2) DO_SECUREBOOT="mok-shim" ;;
    3) DO_SECUREBOOT="custom-db" ;;
    *) DO_SECUREBOOT="no" ;;
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
  if [[ "$NVIDIA_PRESENT" -eq 0 ]]; then
    section "NVIDIA"
    hint "No NVIDIA GPU detected (lspci) — nothing to do here."
    return 0
  fi
  section "NVIDIA"
  kv "driver" "$NVIDIA_SRC ${NVIDIA_VER:-} (signer: ${NVIDIA_SIGNER:-none/unsigned})"
  kv "dkms mods" "${NVIDIA_DKMS_MODS:-none}"
  kv "module key" "${NVIDIA_KEY:-none} (enrolled: $NVIDIA_ENROLLED)"
  kv "lockdown" "$(cat /sys/kernel/security/lockdown 2>/dev/null || echo n/a)"
  if [[ "$NVIDIA_ENROLLED" == "no" ]]; then
    warn "NVIDIA/DKMS key NOT enrolled: enabling SB now = black screen + no WiFi until fixed."
    hint "The Secure Boot setup offers one-key unification (recommended)."
  fi
}

nvidia_menu() {
  # Called inside SB setup (keys exist). Decides unification. Sets DO_NVIDIA.
  DO_NVIDIA="skip"
  nvidia_detect
  if [[ "$NVIDIA_PRESENT" -eq 0 ]]; then return 0; fi
  section "NVIDIA Secure Boot"
  kv "driver" "$NVIDIA_SRC $NVIDIA_VER (signer: ${NVIDIA_SIGNER:-?}, key enrolled: $NVIDIA_ENROLLED)"
  if [[ "$NVIDIA_SRC" == "dkms" ]]; then
    bullet "Point DKMS at your Limine MOK ($SB_KEYS)"
    bullet "Rebuild modules for every installed kernel"
    bullet "One enrollment covers Limine + NVIDIA + WiFi DKMS modules"
    local ans
    if [[ "$ASSUME_YES" -eq 1 ]]; then ans="yes"; else ans="$(ask_yes_no "Unify DKMS signing key?" "yes")"; fi
    [[ "$ans" == "yes" ]] && DO_NVIDIA="unify" || DO_NVIDIA="skip"
  elif [[ "$NVIDIA_SRC" == "rpm-akmods" ]]; then
    bullet "RPM Fusion akmods uses its own key ($NVIDIA_KEY)"
    bullet "Enroll it alongside the Limine MOK in the same MokManager session"
    local ans
    if [[ "$ASSUME_YES" -eq 1 ]]; then ans="yes"; else ans="$(ask_yes_no "Enroll akmods key too?" "yes")"; fi
    [[ "$ans" == "yes" ]] && DO_NVIDIA="enroll-akmods" || DO_NVIDIA="skip"
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "backup $DKMS_CONF + set mok_signing_key/certificate"; return 0; fi
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
      if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "dkms autoinstall -k $ver"; continue; fi
      run dkms autoinstall -k "$ver" || warn "dkms autoinstall failed for $ver (see dkms status)"
      built=$((built + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  ok "DKMS rebuild done (rebuilt: $built, already-good: $skipped)."
  if [[ "$DRY_RUN" -eq 0 ]]; then dkms status 2>/dev/null | head -n 10 | ui_indent || true; fi
}

nvidia_verify() {
  # Report per-kernel nvidia signer. Warns, never fails.
  local ver f s
  for b in /lib/modules/*/build; do
    ver="$(basename "$(dirname "$b")")"
    f="$(find "/lib/modules/$ver/extra" -name 'nvidia.ko*' 2>/dev/null | head -n1 || true)"
    if [[ -z "$f" ]]; then printf '  %s%s: no nvidia module%s\n' "$C_DIM" "$ver" "$C_RST"; continue; fi
    s="$(modinfo -F signer "$f" 2>/dev/null || echo ERROR)"
    printf '  %s: signer=%s%s%s\n' "$ver" "'" "$s" "'"
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "append limine sync to post_transaction in $DKMS_CONF"; return 0; fi
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
    if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "remove limine lines from $DKMS_CONF"; return 0; fi
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
        dry_print "mokutil --import $NVIDIA_KEY"
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

# ---------------------------------------------------------------- cachyos ----

# Detect CachyOS kernels (from bieszczaders/kernel-cachyos COPR repo).
cachyos_detect() {
  CACHYOS_PRESENT=0
  CACHYOS_KERNELS=""
  ls /boot/vmlinuz-*cachyos* >/dev/null 2>&1 || return 0
  CACHYOS_PRESENT=1
  CACHYOS_KERNELS="$(ls -1 /boot/vmlinuz-*cachyos* 2>/dev/null | sort -Vr || true)"
}

# Sign a single kernel (vmlinuz path) with the SB MOK key.
cachyos_sign_kernel() {
  local kpath="$1" dir="${2:-$SB_KEY_DIR_DEFAULT}"
  [[ -f "$kpath" ]] || return 0
  if ! sb_keys_present "$dir"; then
    warn "cachyos-sign: SB keys missing in $dir — skipping sign of $kpath"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry_print "sbsign $kpath"
    return 0
  fi
  command -v sbsign >/dev/null 2>&1 || { warn "sbsign missing — cannot sign $kpath"; return 0; }
  local tmp
  tmp="$(mktemp /tmp/limine-cachyos-sign-XXXXXX)"
  run sbsign --key "$dir/MOK.priv" --cert "$dir/MOK.pem" --output "$tmp" "$kpath" \
    || { rm -f "$tmp"; warn "sbsign failed for $kpath"; return 1; }
  run mv "$tmp" "$kpath"
  if command -v sbverify >/dev/null 2>&1; then
    run sbverify --cert "$dir/MOK.pem" "$kpath" || warn "sbverify failed for $kpath"
  fi
  command -v restorecon >/dev/null 2>&1 && restorecon "$kpath" 2>/dev/null || true
  ok "Signed CachyOS kernel: $(basename "$kpath")"
}

# Sign all CachyOS kernels on /boot.
cachyos_sign_all() {
  local dir="${1:-$SB_KEY_DIR_DEFAULT}" k
  cachyos_detect || true
  [[ "$CACHYOS_PRESENT" -eq 1 ]] || return 0
  log "Signing CachyOS kernels with SB MOK key..."
  for k in $CACHYOS_KERNELS; do
    cachyos_sign_kernel "$k" "$dir"
  done
}

# Install kernel-install hook that auto-signs CachyOS kernels on every update.
cachyos_hook_install() {
  local hook="/etc/kernel/install.d/94-cachyos-sign.install"
  [[ "$DRY_RUN" -eq 1 ]] && { dry_print "write $hook"; return 0; }
  cat > "$hook" <<'HOOK_EOF'
#!/usr/bin/env bash
# 94-cachyos-sign.install — Auto-sign CachyOS kernels on every kernel install/update.
# Runs BEFORE 95-limine.install so signed kernels are copied to ESP.
# COPR CachyOS kernels are unsigned and will NOT boot under Secure Boot without this.
set -euo pipefail
SB_KEY_DIR="${SB_KEY_DIR:-/etc/limine/keys}"
# Only act for CachyOS kernels.
[[ "${1:-}" == *"cachyos"* ]] || exit 0
command -v sbsign >/dev/null 2>&1 || exit 0
[[ -f "$SB_KEY_DIR/MOK.priv" && -f "$SB_KEY_DIR/MOK.pem" ]] || exit 0
# kernel-install calls: $1=kernel-version $2=boot-loader-id $3=machine-id $4=kernel-image-path
kimg="${4:-}"
[[ -n "$kimg" && -f "$kimg" ]] || exit 0
tmp="$(mktemp /tmp/limine-cachyos-sign-XXXXXX)"
sbsign --key "$SB_KEY_DIR/MOK.priv" --cert "$SB_KEY_DIR/MOK.pem" \
  --output "$tmp" "$kimg" && mv "$tmp" "$kimg"
command -v sbverify >/dev/null 2>&1 && sbverify --cert "$SB_KEY_DIR/MOK.pem" "$kimg" || true
command -v restorecon >/dev/null 2>&1 && restorecon "$kimg" 2>/dev/null || true
HOOK_EOF
  chmod +x "$hook"
  ok "CachyOS auto-sign hook installed: $hook"
}

cachyos_menu() {
  # Post-install / sb-setup choice. Sets DO_CACHYOS (yes/no).
  # Preserves a pre-seeded "yes" from the install wizard (no double-ask).
  if [[ "${DO_CACHYOS:-no}" == "yes" ]]; then return 0; fi
  DO_CACHYOS="no"
  cachyos_detect || true
  [[ "${CACHYOS_PRESENT:-0}" -eq 1 ]] || return 0
  section "CachyOS kernel Secure Boot signing"
  kv "detected" "${CACHYOS_KERNELS//$'\n'/ }"
  warn "CachyOS kernels are unsigned — Fedora's shim rejects them under Secure Boot"
  hint "('bad shim signature') unless you self-sign them with a MOK key."
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    warn "--yes: CachyOS kernel signing skipped."
    return 0
  fi
  local r
  r="$(ask_yes_no "Self-sign CachyOS kernel(s) with MOK + auto-sign on updates?" "yes")"
  [[ "$r" == "yes" ]] && DO_CACHYOS="yes" || DO_CACHYOS="no"
}

cachyos_install_menu() {
  # Install-wizard choice. Sets DO_CACHYOS_INSTALL (0/1) + DO_CACHYOS (yes/no).
  # Detects Secure Boot (SB_STATE) and warns about 'bad shim signature'.
  # --yes keeps defaults: no install, no signing.
  DO_CACHYOS_INSTALL=0
  [[ "${DO_CACHYOS:-no}" == "yes" ]] || DO_CACHYOS="no"
  section "CachyOS kernel (COPR, optional)"
  cachyos_detect || true
  if [[ "${CACHYOS_PRESENT:-0}" -eq 1 ]]; then
    kv "installed" "${CACHYOS_KERNELS//$'\n'/ }"
  else
    echo "  Install kernel-cachyos (+ -core, -modules, -devel-matched) from COPR?"
    hint "sudo dnf copr enable bieszczaders/kernel-cachyos"
    hint "sudo dnf install kernel-cachyos kernel-cachyos-devel-matched"
    if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
    local r
    r="$(ask_yes_no "Install CachyOS kernel from COPR?" "no")"
    [[ "$r" == "yes" ]] && DO_CACHYOS_INSTALL=1 || DO_CACHYOS_INSTALL=0
    [[ "$DO_CACHYOS_INSTALL" -eq 1 ]] || return 0
  fi
  # At this point a CachyOS kernel is present or will be installed: offer SB setup.
  if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
  local want_sign="no" def="no"
  if [[ "${SB_STATE:-unknown}" == "enabled" ]]; then
    warn "Secure Boot is ENABLED and COPR CachyOS kernels are UNSIGNED."
    hint "Fedora's shim will reject them ('bad shim signature') unless you:"
    hint "• disable Secure Boot in firmware (easiest), or"
    hint "• self-sign via MOK (recommended: one enrollment, auto-signs on updates)"
    def="yes"
  else
    hint "CachyOS kernels are unsigned: fine with Secure Boot off, they need MOK self-signing when it's on."
    def="no"
  fi
  want_sign="$(ask_yes_no "Self-sign CachyOS kernel(s) with MOK + auto-sign on updates?" "$def")"
  if [[ "$want_sign" == "yes" ]]; then
    DO_CACHYOS="yes"
    if [[ "${DO_SECUREBOOT:-no}" == "no" ]]; then
      DO_SECUREBOOT="mok-shim"
      ok "Secure Boot method set to mok-shim (covers Limine + CachyOS kernel, one MOK)."
    fi
    hint "Next boot: MokManager (blue screen) → Enroll MOK → Continue → Yes."
  else
    DO_CACHYOS="no"
    if [[ "${SB_STATE:-unknown}" == "enabled" ]]; then
      warn "Without MOK signing you must DISABLE Secure Boot in firmware before a CachyOS kernel will boot."
      warn "Fedora default kernels keep working under Secure Boot regardless."
    fi
  fi
}

install_cachyos_kernel() {
  [[ "${DO_CACHYOS_INSTALL:-0}" -eq 1 ]] || return 0
  log "Installing CachyOS kernel from COPR (bieszczaders/kernel-cachyos)..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry_print "dnf copr enable -y bieszczaders/kernel-cachyos"
    dry_print "dnf install -y kernel-cachyos kernel-cachyos-core kernel-cachyos-modules kernel-cachyos-devel-matched"
    return 0
  fi
  run dnf copr enable -y bieszczaders/kernel-cachyos \
    || warn "copr enable failed (may already be enabled; continuing)."
  # NOTE: kernel-cachyos itself is a small metapackage — vmlinuz lives in
  # -core, drivers in -modules. Install all explicitly: a system can end up
  # with the meta package present but no /boot files if -core never landed
  # (the classic "CachyOS kernel not in the Limine menu" cause).
  run dnf install -y kernel-cachyos kernel-cachyos-core kernel-cachyos-modules \
    kernel-cachyos-devel-matched \
    || die "CachyOS kernel install failed."
  if ls /boot/vmlinuz-*cachyos* >/dev/null 2>&1; then
    ok "CachyOS kernel present: $(ls -1 /boot/vmlinuz-*cachyos* 2>/dev/null | tr '\n' ' ')"
  else
    warn "kernel-cachyos installed but no /boot/vmlinuz-*cachyos* exists!"
    warn "Check: rpm -q kernel-cachyos-core kernel-cachyos-modules"
    warn "Fix:   sudo dnf reinstall -y kernel-cachyos-core kernel-cachyos-modules"
    warn "Continuing Limine install anyway — re-run sudo limine-update once fixed."
  fi
}

# ---------------------------------------------------------------- themes ---
# Boot theme catalog. A theme = global limine.conf directives (palette,
# interface colours, wallpaper, font) + optional assets on the ESP.
# Palette-only themes need no assets; wallpaper/font themes download them.
# Snippets are stored filtered (generator-owned timeout/default_entry/
# remember_last_entry stripped) in $THEME_SNIPPET (/etc/limine/theme.conf)
# and emitted by limine-fedora-sync on every regen. THEME_NAME is recorded
# in /etc/default/limine + the install state file.
#
# NOTE on Fallout: the Commonfatedisinflation68/fallout-limine-theme repo
# linked in the request ships no usable Limine files (its zip contains only
# unrelated Windows binaries: binl.exe, lua51.dll, ...). The 'fallout' option
# below uses Neptune3013/fallout-limine-theme (Pip-Boy green, limine.conf
# snippet + background.jpg + font, incl. an SB-aware installer upstream).

THEME_IDS="catppuccin-mocha catppuccin-latte catppuccin-frappe catppuccin-macchiato tokyo-night nord rose-pine cachyos fallout fallout-alt lumon thinkpad j0x sekiro shiro synthwave apex spitfire arch squatchware scary-cat none"

theme_desc() {
  case "${1:-}" in
    catppuccin-mocha) echo "Catppuccin Mocha, mauve accent (default)" ;;
    catppuccin-latte) echo "Catppuccin Latte, mauve accent (light)" ;;
    catppuccin-frappe) echo "Catppuccin Frappe, mauve accent" ;;
    catppuccin-macchiato) echo "Catppuccin Macchiato, mauve accent" ;;
    tokyo-night) echo "Tokyo Night (night variant)" ;;
    nord) echo "Nord (arctic palette)" ;;
    rose-pine) echo "Rose Pine (main variant)" ;;
    cachyos) echo "CachyOS (teal + logo wallpaper)" ;;
    fallout) echo "Fallout Pip-Boy green + terminal font" ;;
    fallout-alt) echo "Fallout splash green + wallpaper" ;;
    lumon) echo "Lumon CRT terminal (Severance) + wallpaper" ;;
    thinkpad) echo "ThinkPad (wallpaper + font)" ;;
    j0x) echo "J0X ultra-minimal black + wallpaper" ;;
    sekiro) echo "Sekiro ink red + wallpaper" ;;
    shiro) echo "Shiro blue + wallpaper" ;;
    synthwave) echo "Synthwave84 neon red + wallpaper" ;;
    apex) echo "Apex cyan + wallpaper" ;;
    spitfire) echo "Spitfire cyan + wallpaper" ;;
    arch) echo "Arch cyan + wallpaper" ;;
    squatchware) echo "Squatchware gold/green + wallpaper" ;;
    scary-cat) echo "Scary Cat purple + wallpaper/font" ;;
    none) echo "None (generator defaults, no theme)" ;;
    *) echo "unknown theme: $1" ;;
  esac
}

theme_valid() {
  [[ " $THEME_IDS " == *" ${1:-} "* ]]
}

theme_snippet_url() {
  case "${1:-}" in
    catppuccin-mocha) echo "https://raw.githubusercontent.com/catppuccin/limine/main/themes/mocha/catppuccin-mocha-mauve.conf" ;;
    catppuccin-latte) echo "https://raw.githubusercontent.com/catppuccin/limine/main/themes/latte/catppuccin-latte-mauve.conf" ;;
    catppuccin-frappe) echo "https://raw.githubusercontent.com/catppuccin/limine/main/themes/frappe/catppuccin-frappe-mauve.conf" ;;
    catppuccin-macchiato) echo "https://raw.githubusercontent.com/catppuccin/limine/main/themes/macchiato/catppuccin-macchiato-mauve.conf" ;;
    tokyo-night) echo "https://raw.githubusercontent.com/Bukutsu/tokyo-night-limine/main/tokyo-night.conf" ;;
    nord) echo "https://raw.githubusercontent.com/vulcan-mode/nord-limine/master/themes/nord.conf" ;;
    rose-pine) echo "https://raw.githubusercontent.com/rose-pine/limine/main/themes/rose-pine.conf" ;;
    lumon) echo "https://raw.githubusercontent.com/ozzium/lumon-limine-theme/main/theme.conf" ;;
    thinkpad) echo "https://raw.githubusercontent.com/T-450/thinkpad-boot-themes/main/limine/limine-theme-snippet.conf" ;;
    fallout) echo "https://raw.githubusercontent.com/Neptune3013/fallout-limine-theme/main/Fallout_limine/Limine.txt" ;;
    shiro) echo "https://raw.githubusercontent.com/eusp/shiro-limine/main/theme.conf" ;;
    j0x) echo "https://raw.githubusercontent.com/John-Varghese-EH/Limine-Theme-J0X/main/theme.conf" ;;
    squatchware) echo "https://raw.githubusercontent.com/squatchware/omarchy-squatchware-theme/main/extras/bootloader/limine-squatchware.conf" ;;
    synthwave) echo "https://raw.githubusercontent.com/Blackshield-Company/cachyos-synthwave84/master/configs/limine/limine-theme.conf" ;;
    *) echo "" ;;
  esac
}

theme_assets() {
  # Prints "url|esp-relative-dest" lines (empty = palette-only theme).
  case "${1:-}" in
    cachyos) echo "https://raw.githubusercontent.com/diegons490/cachyos-limine-theme/main/cachyos.png|cachyos.png" ;;
    fallout)
      echo "https://raw.githubusercontent.com/Neptune3013/fallout-limine-theme/main/Fallout_limine/background.jpg|background.jpg"
      echo "https://raw.githubusercontent.com/Neptune3013/fallout-limine-theme/main/Fallout_limine/PHXEGA8.F14|PHXEGA8.F14"
      ;;
    lumon) echo "https://raw.githubusercontent.com/ozzium/lumon-limine-theme/main/wallpaper.png|lumon-limine-theme/wallpaper.png" ;;
    thinkpad)
      echo "https://raw.githubusercontent.com/T-450/thinkpad-boot-themes/main/limine/thinkpad-wallpaper.png|limine/thinkpad-wallpaper.png"
      echo "https://raw.githubusercontent.com/T-450/thinkpad-boot-themes/main/limine/thinkpad-font.bin|limine/thinkpad-font.bin"
      ;;
    shiro) echo "https://raw.githubusercontent.com/eusp/shiro-limine/main/background.png|shiro-limine/background.png" ;;
    j0x) echo "https://raw.githubusercontent.com/John-Varghese-EH/Limine-Theme-J0X/main/background.jpeg|limine-bg.jpeg" ;;
    sekiro) echo "https://raw.githubusercontent.com/Meliodas-96/sekiro_limine_theme/main/Sekiro/sekiro_1920x1080.png|themes/sekiro/sekiro_1920x1080.png" ;;
    fallout-alt) echo "https://raw.githubusercontent.com/magicdude4eva/fallout-limine-theme/refs/heads/main/splash-limine-fallout.png|splash-limine-fallout.png" ;;
    synthwave) echo "https://raw.githubusercontent.com/Blackshield-Company/cachyos-synthwave84/master/configs/limine/limine-splash-synthwave.png|limine-splash.png" ;;
    apex) echo "https://raw.githubusercontent.com/claudemods/apex-limine-theme/main/install/rift.jpg|rift.jpg" ;;
    spitfire) echo "https://raw.githubusercontent.com/claudemods/spitfire-limine-theme/main/install/spitfire.png|spitfire.png" ;;
    arch) echo "https://raw.githubusercontent.com/claudemods/arch-limine-theme/main/install/archcustom.png|archcustom.png" ;;
    squatchware) echo "https://raw.githubusercontent.com/squatchware/omarchy-squatchware-theme/main/extras/bootloader/squatchware-boot.png|squatchware-boot.png" ;;
    scary-cat)
      echo "https://raw.githubusercontent.com/arnaud-ma/scary-cat-limine-theme/main/limine/scary_cat.png|EFI/limine/scary_cat.png"
      echo "https://raw.githubusercontent.com/arnaud-ma/scary-cat-limine-theme/main/limine/SCRWL---.F16|EFI/limine/SCRWL---.F16"
      ;;
    *) true ;;
  esac
}

theme_embedded_snippet() {
  # Static snippet for themes without a downloadable conf (cachyos PARAMS
  # from upstream setup.sh, minus generator-owned timeout/default_entry).
  case "${1:-}" in
    cachyos)
      cat <<'EMBED_EOF'
term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_background: ffffffff
term_foreground: cdd6f4
term_background_bright: ffffffff
term_foreground_bright: cdd6f4
wallpaper: boot():/cachyos.png
interface_branding:
EMBED_EOF
      ;;
    sekiro)
      # From upstream install.sh template (dropped non-Limine 'graphics:' key).
      cat <<'EMBED_EOF'
interface_resolution: 1920x1080
wallpaper: boot():/themes/sekiro/sekiro_1920x1080.png
wallpaper_style: stretched
interface_branding: Sekiro
interface_branding_colour: b14046
interface_help_colour: b14046
interface_help_colour_bright: f0a0a0
term_background: 80000000
term_foreground: ffffff
term_background_bright: 40000000
term_foreground_bright: ffffff
term_margin: 64
term_margin_gradient: 8
term_palette: 120b0b;8f1d2c;5f6b3a;b8863b;3e4b6b;7d3152;557a78;d8c9b0
term_palette_bright: 4d4141;d94b5b;93a85b;e0b85c;6477a8;bd5e8a;7da9a2;fff4dc
EMBED_EOF
      ;;
    fallout-alt)
      # PARAMS from upstream setup.sh + wallpaper line (SB hash appended at regen).
      cat <<'EMBED_EOF'
term_palette: 000000;ff0000;67d97a;ffff00;0000ff;ff00ff;67d97a;ffffff
term_palette_bright: 333333;ff0000;67d97a;ffff00;0000ff;ff00ff;67d97a;ffffff
term_background: ffffffff
term_foreground: 67d97a
term_background_bright: ffffffff
term_foreground_bright: ffffff
interface_branding:
wallpaper: boot():/splash-limine-fallout.png
EMBED_EOF
      ;;
    apex)
      cat <<'EMBED_EOF'
term_palette: 1e1e2e;f38ba8;a6e3a1;24ffff;89b4fa;f5c2e7;24ffff;24ffff
term_palette_bright: 24ffff;f38ba8;a6e3a1;24ffff;89b4fa;f5c2e7;24ffff;24ffff
term_foreground: 24ffff
term_foreground_bright: f38ba8
wallpaper: boot():/rift.jpg
interface_branding:
EMBED_EOF
      ;;
    spitfire)
      cat <<'EMBED_EOF'
term_palette: 1e1e2e;f38ba8;a6e3a1;24ffff;89b4fa;f5c2e7;24ffff;24ffff
term_palette_bright: 24ffff;f38ba8;a6e3a1;24ffff;89b4fa;f5c2e7;24ffff;24ffff
term_foreground: 24ffff
term_foreground_bright: f38ba8
wallpaper: boot():/spitfire.png
interface_branding:
EMBED_EOF
      ;;
    arch)
      cat <<'EMBED_EOF'
term_palette: 1e1e2e;f38ba8;a6e3a1;24ffff;89b4fa;f5c2e7;24ffff;24ffff
term_palette_bright: 24ffff;f38ba8;a6e3a1;24ffff;89b4fa;f5c2e7;24ffff;24ffff
term_foreground: 24ffff
term_foreground_bright: f38ba8
wallpaper: boot():/archcustom.png
interface_branding:
EMBED_EOF
      ;;
    scary-cat)
      # UI section of upstream limine.conf (boot entries excluded upstream by
      # design here; fixed upstream 'streched' typo).
      cat <<'EMBED_EOF'
interface_branding: Scary cat bootloader
interface_branding_colour: 5
interface_help_hidden: no
term_font: boot():/EFI/limine/SCRWL---.F16
term_font_size: 8x16
term_font_scale: 2x2
term_font_spacing: 1
term_margin: 0
term_margin_gradient: 0
wallpaper: boot():/EFI/limine/scary_cat.png
wallpaper_style: stretched
term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;bac2de
term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;f5c2e7;94e2d5;cdd6f4
term_foreground: cdd6f4
term_foreground_bright: cdd6f4
EMBED_EOF
      ;;
    *) return 1 ;;
  esac
}

theme_filter_snippet() {
  # Strip generator-owned keys (timeout/default_entry/remember_last_entry).
  # Reads a file, or stdin when called with no args / "-".
  local src="${1:-/dev/stdin}"
  [[ "$src" == "-" ]] && src="/dev/stdin"
  grep -vE '^[[:space:]]*(timeout|default_entry|remember_last_entry)[[:space:]]*:' "$src"
}

theme_extra_lines() {
  # Extra snippet lines a theme needs beyond its downloadable conf
  # (e.g. J0X injects its wallpaper line via install.sh upstream).
  case "${1:-}" in
    j0x) echo "wallpaper: boot():/limine-bg.jpeg" ;;
    *) true ;;
  esac
}

config_set_key() {
  # config_set_key <file> <KEY> <value> — idempotent KEY="value" setter.
  local f="$1" k="$2" v="$3"
  [[ -f "$f" ]] || die "No $f (run install first)."
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "set $k=\"$v\" in $f"; return 0; fi
  if grep -q "^$k=" "$f"; then
    run sed -i "s|^$k=.*|$k=\"$v\"|" "$f"
  else
    echo "$k=\"$v\"" >> "$f"
  fi
}

fetch_theme() {
  # fetch_theme <id> <esp> — download snippet + assets, record THEME_NAME.
  # Returns 0 on success (or 'none'), 1 when download failed (caller falls
  # back to unthemed + warns; install must never abort on a theme).
  local id="$1" esp="$2" url line aurl dest
  theme_valid "$id" || { warn "Unknown theme: $id"; return 1; }
  if [[ "$id" == "none" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "theme=none (remove $THEME_SNIPPET)"; return 0; fi
    rm -f "$THEME_SNIPPET" 2>/dev/null || true
    config_set_key "$CONFIG_FILE" "THEME_NAME" "none"
    ok "Theme cleared (generator defaults)."
    return 0
  fi
  log "Fetching theme: $id ($(theme_desc "$id")) ..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry_print "snippet -> $THEME_SNIPPET; assets -> $esp/"
    return 0
  fi
  local tmp
  tmp="$(mktemp /tmp/limine-theme-XXXXXX.conf)"
  if theme_embedded_snippet "$id" > "$tmp" 2>/dev/null; then
    : # built-in snippet
  else
    url="$(theme_snippet_url "$id")"
    [[ -n "$url" ]] || { warn "No snippet source for theme $id"; rm -f "$tmp"; return 1; }
    if ! curl -fsSL --max-time 30 -o "$tmp" "$url"; then
      warn "Theme download failed ($url) — continuing without theme."
      rm -f "$tmp"
      return 1
    fi
  fi
  [[ -s "$tmp" ]] || { warn "Empty theme snippet for $id — continuing without theme."; rm -f "$tmp"; return 1; }
  mkdir -p "$(dirname "$THEME_SNIPPET")"
  theme_filter_snippet "$tmp" > "$THEME_SNIPPET"
  theme_extra_lines "$id" | theme_filter_snippet >> "$THEME_SNIPPET"
  rm -f "$tmp"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    aurl="${line%%|*}"; dest="$esp/${line#*|}"
    mkdir -p "$(dirname "$dest")"
    if curl -fsSL --max-time 60 -o "$dest" "$aurl" && [[ -s "$dest" ]]; then
      log "  asset -> ${dest#$esp/}"
    else
      warn "  asset download failed ($aurl) — theme may render without wallpaper/font."
      rm -f "$dest"
    fi
  done < <(theme_assets "$id")
  config_set_key "$CONFIG_FILE" "THEME_NAME" "$id"
  ok "Theme applied: $id"
  return 0
}

theme_menu() {
  # Wizard choice. Sets DO_THEME_ID (never downloads here).
  section "Boot theme"
  hint "Catppuccin Mocha is the default. A theme sets palette, colours, wallpaper and font."
  hint "Applied before the kernel sync; switch anytime with:  sudo $0 --theme"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    DO_THEME_ID="catppuccin-mocha"
    return 0
  fi
  local choice
  choice="$(ask_numbered "Theme" \
    "catppuccin-mocha (default)" \
    "catppuccin-latte (light)" \
    "catppuccin-frappe" \
    "catppuccin-macchiato" \
    "tokyo-night" \
    "nord" \
    "rose-pine" \
    "cachyos (+ wallpaper)" \
    "fallout Pip-Boy (+ wallpaper/font)" \
    "fallout-alt splash (+ wallpaper)" \
    "lumon CRT (+ wallpaper)" \
    "thinkpad (+ wallpaper/font)" \
    "j0x minimal (+ wallpaper)" \
    "sekiro (+ wallpaper)" \
    "shiro (+ wallpaper)" \
    "synthwave84 (+ wallpaper)" \
    "apex (+ wallpaper)" \
    "spitfire (+ wallpaper)" \
    "arch (+ wallpaper)" \
    "squatchware (+ wallpaper)" \
    "scary-cat (+ wallpaper/font)" \
    "none (no theme)")"
  case "$choice" in
    1) DO_THEME_ID="catppuccin-mocha" ;;
    2) DO_THEME_ID="catppuccin-latte" ;;
    3) DO_THEME_ID="catppuccin-frappe" ;;
    4) DO_THEME_ID="catppuccin-macchiato" ;;
    5) DO_THEME_ID="tokyo-night" ;;
    6) DO_THEME_ID="nord" ;;
    7) DO_THEME_ID="rose-pine" ;;
    8) DO_THEME_ID="cachyos" ;;
    9) DO_THEME_ID="fallout" ;;
    10) DO_THEME_ID="fallout-alt" ;;
    11) DO_THEME_ID="lumon" ;;
    12) DO_THEME_ID="thinkpad" ;;
    13) DO_THEME_ID="j0x" ;;
    14) DO_THEME_ID="sekiro" ;;
    15) DO_THEME_ID="shiro" ;;
    16) DO_THEME_ID="synthwave" ;;
    17) DO_THEME_ID="apex" ;;
    18) DO_THEME_ID="spitfire" ;;
    19) DO_THEME_ID="arch" ;;
    20) DO_THEME_ID="squatchware" ;;
    21) DO_THEME_ID="scary-cat" ;;
    22) DO_THEME_ID="none" ;;
    *) DO_THEME_ID="catppuccin-mocha" ;;
  esac
}

install_state_present() {
  [[ -f "$STATE_FILE" ]] && config_is_valid "$STATE_FILE"
}

install_state_summary() {
  [[ -f "$STATE_FILE" ]] || { echo "  (no previous install recorded)"; return 0; }
  local INSTALL_DATE="?" LAST_UPDATE="?" LIMINE_VER_S="?" ESP_S="?" THEME_NAME_S="?" SECURE_BOOT_S="?"
  # shellcheck disable=SC1090
  . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$STATE_FILE" 2>/dev/null || true) || true
  INSTALL_DATE="${INSTALL_DATE:-?}"; LAST_UPDATE="${LAST_UPDATE:-?}"
  LIMINE_VER_S="${LIMINE_VER:-?}"; ESP_S="${ESP:-?}"
  THEME_NAME_S="${THEME_NAME:-?}"; SECURE_BOOT_S="${SECURE_BOOT:-?}"
  kv "installed" "$INSTALL_DATE   (last change: $LAST_UPDATE)"
  kv "limine" "$LIMINE_VER_S"
  kv "ESP" "$ESP_S"
  kv "theme" "$THEME_NAME_S"
  kv "secure boot" "$SECURE_BOOT_S"
}

write_install_state() {
  # write_install_state [limine_ver] — record/refresh install state.
  # Preserves INSTALL_DATE + LIMINE_VER ("keep") across re-runs.
  local ver="${1:-keep}" now old_date="?" old_ver="?"
  now="$(date +%F-%H%M%S)"
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "write $STATE_FILE"; return 0; fi
  if [[ -f "$STATE_FILE" ]]; then
    old_date="$(grep '^INSTALL_DATE=' "$STATE_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    old_ver="$(grep '^LIMINE_VER=' "$STATE_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    [[ -n "${old_date:-}" ]] && old_date="$old_date" || old_date="$now"
    [[ "$ver" == "keep" ]] && ver="${old_ver:-unknown}"
  else
    old_date="$now"
    [[ "$ver" == "keep" ]] && ver="unknown"
  fi
  local theme="none" sbm="no" esp_p="${ESP:-unknown}" mid="${MACHINE:-unknown}"
  if [[ -f "$CONFIG_FILE" ]]; then
    theme="$(grep '^THEME_NAME=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    sbm="$(grep '^SECURE_BOOT=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
  fi
  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$STATE_FILE" <<EOF
# fedora-limine-switch install state — written automatically, do not edit.
# Presence of this file (valid KEY="value" lines only) means the installer ran.
INSTALL_DATE="$old_date"
LAST_UPDATE="$now"
LIMINE_VER="$ver"
ESP="${esp_p:-unknown}"
MACHINE_ID="${mid:-unknown}"
THEME_NAME="${theme:-none}"
SECURE_BOOT="${sbm:-no}"
EOF
  log "Install state recorded: $STATE_FILE"
}

theme_flow() {
  # Standalone theme install/switch on an existing install. $1 = id or ask.
  local method="${1:-ask}" esp
  need_root
  [[ -f "$SYNC_SCRIPT" || -f "$CONFIG_FILE" ]] || die "Not installed (no $SYNC_SCRIPT). Run install first."
  esp="$(detect_esp)" || die "ESP not found."
  sb_config_load 2>/dev/null || true
  local id="$method"
  if [[ "$id" == "ask" ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      id="catppuccin-mocha"
    else
      theme_menu  # sets DO_THEME_ID
      id="$DO_THEME_ID"
    fi
  fi
  theme_valid "$id" || die "Unknown theme: $id (choices: $THEME_IDS)"
  if ! fetch_theme "$id" "$esp"; then
    warn "Theme '$id' could not be applied (downloads failed). Keeping previous visuals."
    return 0
  fi
  log "Refreshing sync script (theme-aware) + regenerating limine.conf..."
  install_hook_and_sync_script
  run "$SYNC_SCRIPT" sync all
  if [[ "${SB_ENROLL:-no}" == "yes" ]]; then
    sb_enroll_and_sign "$esp" "${SB_KEYS:-$SB_KEY_DIR_DEFAULT}"
  fi
  write_install_state keep
  ok "Theme '$id' installed. Reboot to see it (limine.conf regenerated)."
}

# ------------------------------------------------- snapper suite ---------
# Fedora bash port of CachyOS limine-snapper-sync (which is Java + pacman
# hooks and cannot run on Fedora). Provides the same workflow:
#   limine-snapper-sync         regenerate $ESP/limine-snapshots.conf
#   limine-snapper-list         show snapshot boot entries
#   limine-snapper-restore <N>  snapper rollback + ESP re-sync
# plus a snapper plugin trigger and a systemd path unit watching /.snapshots
# so entries refresh automatically. gen_conf() includes the fragment under
# //Snapshots (same keyword CachyOS uses).

SNAP_SYNC_TOOL="/usr/local/sbin/limine-snapper-sync"
SNAP_LIST_TOOL="/usr/local/sbin/limine-snapper-list"
SNAP_RESTORE_TOOL="/usr/local/sbin/limine-snapper-restore"
SNAP_PLUGIN="/usr/lib/snapper/plugins/10-limine-fedora-sync"
SNAP_SERVICE="/usr/lib/systemd/system/limine-snapper-sync.service"
SNAP_PATH_UNIT="/usr/lib/systemd/system/limine-snapper-sync.path"

install_snapper_suite() {
  # $1 = ESP (generators resolve it from /etc/default/limine at runtime).
  log "Installing limine-snapper-sync suite (Fedora port of CachyOS tooling)..."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry_print "write $SNAP_SYNC_TOOL, $SNAP_LIST_TOOL, $SNAP_RESTORE_TOOL, $SNAP_PLUGIN, systemd service+path"
    return 0
  fi

  cat > "$SNAP_SYNC_TOOL" <<'SNAPGEN_EOF'
#!/usr/bin/env bash
# limine-snapper-sync — Fedora port of the CachyOS snapshot entry generator.
# Discovers snapper snapshots, stages per-snapshot kernels on the ESP, writes
# $ESP/limine-snapshots.conf (picked up by limine-fedora-sync under //Snapshots).
# Usage: limine-snapper-sync [sync|list|remove <n1>..<n2>]
set -euo pipefail
CONFIG="/etc/default/limine"
ESP_PATH="${ESP_PATH:-/boot/efi}"
MACHINE_ID="$(cat /etc/machine-id 2>/dev/null | tr -d ' \n')"
KERNEL_CMDLINE=""; ENABLE_SNAPSHOTS="auto"; MAX_SNAPSHOT_ENTRIES="10"
LIMIT_USAGE_PERCENT="85"; EXCLUDE_SNAPSHOT_TYPES="pre, post"
EXCLUDE_SNAPSHOT_ENTRIES="Windows*, windows*"; SNAPSHOT_KERNEL_PARAMETERS=""
SECURE_BOOT="no"; ENABLE_VERIFICATION="no"; TARGET_OS_NAME="Fedora Linux"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$CONFIG" 2>/dev/null || true)
[[ -n "${MACHINE_ID_OVERRIDE:-}" ]] && MACHINE_ID="$MACHINE_ID_OVERRIDE"
[[ -n "${MACHINE_ID:-}" ]] || MACHINE_ID="$(cat /etc/machine-id | tr -d ' \n')"
ESP="${ESP_PATH}"
[[ -d "$ESP" ]] || { echo "limine-snapper-sync: ESP not found: $ESP" >&2; exit 1; }
VERIFY_ON="no"
[[ "${ENABLE_VERIFICATION:-no}" == "yes" || "${SECURE_BOOT:-no}" != "no" ]] && VERIFY_ON="yes"
SNAP_BASE="$ESP/$MACHINE_ID/snapshots"
mkdir -p "$SNAP_BASE"

snapper_cfg() {
  command -v snapper >/dev/null 2>&1 || return 1
  local cfg
  cfg="$(snapper list-configs 2>/dev/null | awk 'NR>1 && $1=="root" {print $1}' | head -n1 || true)"
  [[ -n "$cfg" ]] || cfg="$(snapper list-configs 2>/dev/null | awk 'NR>1 {print $1}' | head -n1 || true)"
  [[ -n "$cfg" ]] && echo "$cfg"
}

snapshots_dir() {
  local cfg="$1" subvol snapdir
  subvol="$(snapper -c "$cfg" get-config 2>/dev/null | grep -E '^SUBVOLUME=' | cut -d'"' -f2 || true)"
  [[ -n "$subvol" ]] || subvol="/"
  snapdir="$subvol/.snapshots"
  [[ -d "$snapdir" ]] || snapdir="/.snapshots"
  [[ -d "$snapdir" ]] && echo "$snapdir"
}

snap_info() { # $1=snapdir $2=num $3=field(number|type|date|description)
  local f="$1/$2/info.xml"
  [[ -f "$f" ]] || return 1
  sed -n "s|.*<$3>\\(.*\\)</$3>.*|\\1|p" "$f" | head -n1
}

excluded_type() { # $1=type
  local t="$1" pat
  IFS=',' read -ra _pats <<< "${EXCLUDE_SNAPSHOT_TYPES:-}"
  for pat in "${_pats[@]}"; do
    pat="$(echo "$pat" | tr -d ' ')"
    [[ -n "$pat" && "$t" == "$pat" ]] && return 0
  done
  return 1
}

excluded_entry() { # $1=description
  local desc="$1" pat
  IFS=',' read -ra _pats <<< "${EXCLUDE_SNAPSHOT_ENTRIES:-}"
  for pat in "${_pats[@]}"; do
    pat="$(echo "$pat" | tr -d ' ')"
    [[ -n "$pat" ]] || continue
    # shellcheck disable=SC2053
    [[ "$desc" == $pat ]] && return 0
  done
  return 1
}

stage_snapshot_kernels() { # $1=num — copy current /boot kernels for snapshot $1
  local n="$1" dest="$SNAP_BASE/$n" v
  mkdir -p "$dest"
  for v in $(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v '^0-rescue' | sort -Vr || true); do
    [[ -f "/boot/vmlinuz-$v" ]] || continue
    [[ -f "$dest/vmlinuz-$v" ]] || cp -p "/boot/vmlinuz-$v" "$dest/vmlinuz-$v" 2>/dev/null || true
    if [[ -f "/boot/initramfs-$v.img" && ! -f "$dest/initramfs-$v.img" ]]; then
      cp -p "/boot/initramfs-$v.img" "$dest/initramfs-$v.img" 2>/dev/null || true
    fi
  done
  command -v restorecon >/dev/null 2>&1 && restorecon -R "$dest" 2>/dev/null || true
}

snapshot_cmdline() { # $1=num — KERNEL_CMDLINE with rootflags pointed at snapshot $1
  local n="$1" cmd subvol snap_path
  cmd="$KERNEL_CMDLINE"
  [[ -z "$cmd" ]] && cmd="$(tr ' ' '\n' < /proc/cmdline | grep -v '^BOOT_IMAGE=' | tr '\n' ' ')"
  subvol="$(findmnt -n -o FS-OPTIONS / 2>/dev/null | tr ',' '\n' | grep '^subvol=' | cut -d= -f2 || true)"
  if [[ -n "$subvol" && "$subvol" != "/" ]]; then
    snap_path="$subvol/.snapshots/$n/snapshot"
  else
    snap_path="/.snapshots/$n/snapshot"
  fi
  if [[ "$cmd" == *"rootflags=subvol="* ]]; then
    cmd="$(echo "$cmd" | sed -E "s|rootflags=subvol=[^ ]*|rootflags=subvol=$snap_path|")"
  else
    cmd="$cmd rootflags=subvol=$snap_path"
  fi
  [[ -n "${SNAPSHOT_KERNEL_PARAMETERS:-}" ]] && cmd="$cmd $SNAPSHOT_KERNEL_PARAMETERS"
  echo "$cmd"
}

do_sync() {
  local cfg snapdir
  cfg="$(snapper_cfg)" || { echo "limine-snapper-sync: no snapper config (create one for / first)" >&2; exit 1; }
  snapdir="$(snapshots_dir "$cfg")" || { echo "limine-snapper-sync: no snapshots dir" >&2; exit 1; }
  local max="${MAX_SNAPSHOT_ENTRIES:-10}" limit="${LIMIT_USAGE_PERCENT:-85}"
  [[ "$max" == "auto" ]] && max=9999
  [[ "$max" =~ ^[0-9]+$ ]] || max=10
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=85
  # Newest snapshots first.
  local nums n stype sdesc kept=0 frag="$ESP/limine-snapshots.conf.tmp"
  nums="$(ls -1 "$snapdir" 2>/dev/null | grep -E '^[0-9]+$' | sort -nr || true)"
  : > "$frag"
  for n in $nums; do
    (( kept >= max )) && break
    [[ -d "$snapdir/$n/snapshot" ]] || continue
    case " ${LIMINE_SKIP_SNAPS:-} " in *" $n "*) continue ;; esac
    stype="$(snap_info "$snapdir" "$n" type 2>/dev/null || echo single)"
    sdesc="$(snap_info "$snapdir" "$n" description 2>/dev/null || echo "snapshot $n")"
    excluded_type "$stype" && continue
    excluded_entry "$sdesc" && continue
    stage_snapshot_kernels "$n"
    local v emit=0 cmd
    cmd="$(snapshot_cmdline "$n")"
    for v in $(ls -1 "$SNAP_BASE/$n"/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -Vr || true); do
      local kf="$SNAP_BASE/$n/vmlinuz-$v" ifile="$SNAP_BASE/$n/initramfs-$v.img"
      local ksuffix="" isuffix=""
      if [[ "$VERIFY_ON" == "yes" ]]; then
        ksuffix="#$(b2sum "$kf" | cut -d' ' -f1)"
        [[ -f "$ifile" ]] && isuffix="#$(b2sum "$ifile" | cut -d' ' -f1)"
      fi
      {
        echo "    //Snapshot $n ($v)"
        echo "    comment: snapper $stype snapshot $n: $sdesc [kernel $v]"
        echo "    protocol: linux"
        echo "    path: boot():/${MACHINE_ID}/snapshots/${n}/vmlinuz-${v}${ksuffix}"
        echo "    cmdline: ${cmd}"
        [[ -f "$ifile" ]] && echo "    module_path: boot():/${MACHINE_ID}/snapshots/${n}/initramfs-${v}.img${isuffix}"
        echo ""
      } >> "$frag"
      emit=1
    done
    (( emit == 1 )) && kept=$((kept+1))
    # ESP usage cap (CachyOS LIMIT_USAGE_PERCENT): stop before overfilling.
    local used
    used="$(df --output=pcent "$ESP" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)"
    if [[ "$used" -ge "$limit" ]]; then
      echo "limine-snapper-sync: ESP at ${used}% (>= $limit%), stopping." >&2
      break
    fi
  done
  mv -f "$frag" "$ESP/limine-snapshots.conf"
  # Prune staged kernels for snapshots that no longer exist.
  local d bn
  for d in "$SNAP_BASE"/*/; do
    [[ -d "$d" ]] || continue
    bn="$(basename "$d")"
    [[ -d "$snapdir/$bn" ]] || rm -rf "$d"
  done
  echo "limine-snapper-sync: $kept snapshot(s) in $ESP/limine-snapshots.conf"
}

do_list() {
  [[ -f "$ESP/limine-snapshots.conf" ]] || { echo "(no snapshot entries yet — run limine-snapper-sync)"; exit 0; }
  grep -E '^    //Snapshot' "$ESP/limine-snapshots.conf" | sed 's/^    /  /' || true
}

do_remove() { # $1 = "n1..n2" — drop staged ESP copies only (never snapper data)
  local range="${1:-}" lo hi
  lo="${range%%..*}"; hi="${range##*..}"
  [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || { echo "Usage: $0 remove <n1>..<n2>" >&2; exit 2; }
  local n skip=""
  for (( n=lo; n<=hi; n++ )); do
    rm -rf "$SNAP_BASE/$n"
    skip+="$n "
  done
  # Re-sync without re-staging the removed range (frees ESP space now).
  LIMINE_SKIP_SNAPS="$skip" do_sync
}

case "${1:-sync}" in
  sync) do_sync ;;
  list) do_list ;;
  remove) do_remove "${2:-}" ;;
  *) echo "Usage: $0 [sync|list|remove <n1>..<n2>]"; exit 2 ;;
esac
SNAPGEN_EOF
  chmod +x "$SNAP_SYNC_TOOL"

  cat > "$SNAP_LIST_TOOL" <<'SNAPLIST_EOF'
#!/usr/bin/env bash
# limine-snapper-list — show Limine snapshot boot entries (CachyOS parity).
set -euo pipefail
exec /usr/local/sbin/limine-snapper-sync list
SNAPLIST_EOF
  chmod +x "$SNAP_LIST_TOOL"

  cat > "$SNAP_RESTORE_TOOL" <<'SNAPREST_EOF'
#!/usr/bin/env bash
# limine-snapper-restore — roll back to a snapper snapshot, then re-sync the ESP.
# Usage: limine-snapper-restore <N>  (uses `snapper rollback`; openSUSE-style
# layouts support it natively, plain Fedora layouts fall back to manual steps).
set -euo pipefail
N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "Usage: $0 <snapshot-number>  (see: snapper list)" >&2; exit 2; }
cfg="$(snapper list-configs 2>/dev/null | awk 'NR>1 {print $1}' | head -n1 || true)"
[[ -n "$cfg" ]] || { echo "No snapper config found." >&2; exit 1; }
if snapper -c "$cfg" rollback "$N"; then
  echo "Rolled back to snapshot $N. Re-syncing ESP..."
  /usr/local/sbin/limine-snapper-sync sync || true
  /usr/local/sbin/limine-fedora-sync sync all || true
  echo "Reboot to boot the restored system."
else
  echo "snapper rollback failed (plain Fedora layouts lack the openSUSE layout)." >&2
  echo "Manual path: mount snapshot $N, rsync it over /, then run:" >&2
  echo "  sudo limine-snapper-sync sync && sudo limine-update" >&2
  exit 1
fi
SNAPREST_EOF
  chmod +x "$SNAP_RESTORE_TOOL"

  # Snapper plugin trigger (CachyOS layout: /usr/lib/snapper/plugins/). The
  # systemd path unit below is the reliable trigger; this covers direct
  # snapper use on systems where snapper executes plugins.
  mkdir -p "$(dirname "$SNAP_PLUGIN")"
  cat > "$SNAP_PLUGIN" <<'SNAPPLUGIN_EOF'
#!/usr/bin/env bash
# 10-limine-fedora-sync — snapper plugin: refresh Limine snapshot entries
# whenever snapshots change, then regenerate limine.conf.
if [[ -x /usr/local/sbin/limine-snapper-sync ]]; then
  /usr/local/sbin/limine-snapper-sync sync >/dev/null 2>&1 || true
fi
if [[ -x /usr/local/sbin/limine-fedora-sync ]]; then
  /usr/local/sbin/limine-fedora-sync conf-only >/dev/null 2>&1 || true
fi
exit 0
SNAPPLUGIN_EOF
  chmod +x "$SNAP_PLUGIN"

  cat > "$SNAP_SERVICE" <<'SNAPSVC_EOF'
[Unit]
Description=Regenerate Limine snapshot boot entries
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/limine-snapper-sync sync
ExecStartPost=/usr/local/sbin/limine-fedora-sync conf-only
SNAPSVC_EOF
  cat > "$SNAP_PATH_UNIT" <<'SNAPPATH_EOF'
[Unit]
Description=Watch snapper snapshots for Limine boot entries

[Path]
PathChanged=/.snapshots

[Install]
WantedBy=multi-user.target
SNAPPATH_EOF
  # Point the watcher at the real snapshots dir when snapper already has one.
  if command -v snapper >/dev/null 2>&1; then
    _snapcfg="$(snapper list-configs 2>/dev/null | awk 'NR>1 {print $1}' | head -n1 || true)"
    if [[ -n "${_snapcfg:-}" ]]; then
      _snapsub="$(snapper -c "$_snapcfg" get-config 2>/dev/null | grep -E '^SUBVOLUME=' | cut -d'"' -f2 || true)"
      if [[ -n "${_snapsub:-}" && -d "$_snapsub/.snapshots" && "$_snapsub/.snapshots" != "/.snapshots" ]]; then
        sed -i "s|^PathChanged=.*|PathChanged=$_snapsub/.snapshots|" "$SNAP_PATH_UNIT"
      fi
    fi
    unset _snapcfg _snapsub
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now limine-snapper-sync.path 2>/dev/null \
      || warn "Could not enable limine-snapper-sync.path (enable manually)."
  else
    warn "systemd not running — enable later: systemctl enable limine-snapper-sync.path"
  fi
  # First generation now (uses current /boot kernels for existing snapshots).
  "$SNAP_SYNC_TOOL" sync || warn "First snapshot sync found no usable snapshots (normal on fresh setups)."
  ok "Snapshot suite installed: limine-snapper-sync/list/restore + systemd watcher."
}

snapper_suite_uninstall() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now limine-snapper-sync.path 2>/dev/null || true
  fi
  rm -f "$SNAP_SYNC_TOOL" "$SNAP_LIST_TOOL" "$SNAP_RESTORE_TOOL" "$SNAP_PLUGIN" \
    "$SNAP_SERVICE" "$SNAP_PATH_UNIT"
}

# ---------------------------------------------------------------- extras ----

extras_menu() {
  section "Optional extras (CachyOS full-suite parity)"
  hint "All optional. Defaults in [brackets]; --yes picks the defaults."

  local r
  r="$(ask_yes_no "Install memtest86+ + add menu entry?" "yes")"; [[ "$r" == "yes" ]] && DO_MEMTEST=1 || DO_MEMTEST=0
  r="$(ask_yes_no "Install EDK2 UEFI Shell + add menu entry?" "no")";  [[ "$r" == "yes" ]] && DO_SHELL=1 || DO_SHELL=0
  r="$(ask_yes_no "Enable snapper/BTRFS snapshot entries if BTRFS?" "yes")"; [[ "$r" == "yes" ]] && DO_SNAPSHOTS="auto" || DO_SNAPSHOTS="no"
  hint "Boot theme is chosen in the next step (separate theme menu)."
}

install_extras() {
  local esp="$1"
  if [[ "$DO_MEMTEST" -eq 1 ]]; then
    log "Installing memtest86+..."
    if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "dnf install memtest86+ + copy to ESP"; else
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
    if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "dnf install edk2-shell-x64 + copy Shell.efi"; else
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
      if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "dnf install snapper btrfs-progs + snapshot suite"; else
        dnf install -y snapper btrfs-progs inotify-tools 2>/dev/null || warn "snapper install failed."
        if ! snapper list-configs 2>/dev/null | awk 'NR>1 {found=1} END {exit !found}'; then
          warn "No snapper config yet. Create one for / (e.g. snapper -c root create-config /),"
          warn "then regenerate entries: sudo limine-snapper-sync sync && sudo limine-update"
        fi
        install_snapper_suite "$esp"
      fi
    fi
  fi
  # Theme is applied by the wizard (fetch_theme) before the kernel sync, so the
  # regenerated conf already carries it; nothing to do here.
  :
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
  if [[ "$DRY_RUN" -eq 1 ]]; then dry_print "backup ESP EFI dirs + /boot/loader + efibootmgr -v"; return 0; fi
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
  section "Verify"
  subhead "ESP contents"
  ls -lh "$esp/EFI/limine/" 2>/dev/null | ui_indent || warn "missing $esp/EFI/limine/"
  ls -lh "$esp/$MACHINE/" 2>/dev/null | ui_indent || ls -lh "$esp/$(machine_id)/" 2>/dev/null | ui_indent || warn "no per-machine kernel dir yet"
  subhead "limine.conf (first 60 lines)"
  head -n 60 "$esp/limine.conf" 2>/dev/null | ui_indent || warn "no $esp/limine.conf"
  subhead "Boot entries"
  efi_list | ui_indent || warn "efibootmgr unavailable"
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
      section "Secure Boot ($sbmode)"
      kv "firmware" "$(secureboot_state | head -n1)"
      hashed="$(grep -c '#[0-9a-fA-F]\{64,\}' "$esp/limine.conf" 2>/dev/null || true)"
      kv "hashed paths" "${hashed:-0} in limine.conf"
      local keydir
      keydir="$(grep '^SB_KEY_DIR=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
      [[ -z "${keydir:-}" ]] && keydir="$SB_KEY_DIR_DEFAULT"
      if [[ -f "$keydir/MOK.pem" ]] && command -v sbverify >/dev/null 2>&1; then
        if sbverify --cert "$keydir/MOK.pem" "$esp/EFI/limine/limine_x64.efi" >/dev/null 2>&1; then
          ok "Signature on limine_x64.efi: VALID (our key)"
        else
          warn "Signature on limine_x64.efi: NOT valid with our key (re-run --sb-resign)"
        fi
      else
        warn "Cannot verify signature (keys/sbverify missing)"
      fi
      if [[ "$sbmode" == "mok-shim" && -f "$esp/EFI/fedora/grubx64.efi.grub-bak" ]]; then
        kv "shim chain" "active (real GRUB in .grub-bak)"
      else
        kv "shim chain" "no GRUB backup (direct boot only)"
      fi
      nvidia_detect
      if [[ "$NVIDIA_PRESENT" -eq 1 ]]; then
        kv "nvidia module" "${NVIDIA_SIGNER:-unsigned?} (key enrolled: $NVIDIA_ENROLLED)"
      fi
    fi
  fi
}

print_next_steps() {
  local n1="${C_CYN}${C_BLD}1.${C_RST}" n2="${C_CYN}${C_BLD}2.${C_RST}"
  local n3="${C_CYN}${C_BLD}3.${C_RST}" n4="${C_CYN}${C_BLD}4.${C_RST}"
  local n5="${C_CYN}${C_BLD}5.${C_RST}"
  section "Next steps (read this!)"
  printf '  %s Reboot. Limine should be first in boot order; the old Fedora/GRUB entry is kept.\n' "$n1"
  printf '  %s Test every kernel entry in Limine. Keep GRUB until you are sure.\n' "$n2"
  printf '  %s Kernel updates happen automatically via the hook:\n     %s\n' "$n3" "$HOOK_FILE"
  printf '     After editing %s, run:  sudo limine-update\n' "$CONFIG_FILE"
  printf '  %s Rollback any time: firmware boot menu → pick "Fedora" (GRUB), or:\n     sudo efibootmgr -o <fedora-num>,<limine-num>\n' "$n4"
  printf '     Full uninstall:  sudo %s --uninstall\n' "$0"
  printf '  %s Only when Limine is proven: remove GRUB (docs/removing-grub.md).\n     Do NOT remove shim/grub blindly — they are dnf-protected for a reason.\n' "$n5"
  # SB-specific next steps (only when configured).
  if [[ -f "$CONFIG_FILE" ]]; then
    local sbmode
    sbmode="$(grep '^SECURE_BOOT=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    if [[ -n "${sbmode:-}" && "$sbmode" != "no" ]]; then
      if [[ "$sbmode" == "mok-shim" ]]; then
        section "Secure Boot (mok-shim) — one more boot"
        bullet "BootOrder puts 'Fedora' (shim) first, so the NEXT boot reaches MokManager."
        bullet "On the blue screen: Enroll MOK → Continue → Yes, then reboot."
        bullet "After that, boot via the 'Fedora' (shim) entry."
        bullet "The direct 'Limine' entry works only with SB off until the MOK is enrolled."
        bullet "Kernel and config updates re-sign automatically via the hook."
      else
        section "Secure Boot (custom-db) — next step"
        bullet "Enroll your key in firmware Setup Mode (docs/secure-boot.md), then:"
        hint "sudo $0 --sb-resign"
      fi
    fi
  fi
  section "Info"
  kv "log" "$LOG_FILE"
  kv "backup" "${BACKUP_DEST:-$BACKUP_ROOT/<timestamp>}"
  kv "docs" "README.md and docs/ (secure boot, snapshots, troubleshooting, GRUB removal)"
}

# ---------------------------------------------------------------- uninstall

do_uninstall() {
  banner
  printf '  %sMode:%s rollback / uninstall\n' "$C_DIM" "$C_RST"
  need_root
  local esp
  esp="$(detect_esp)" || die "ESP not found."
  section "Current boot state"
  kv "ESP" "$esp"
  efi_list | head -n 30 | ui_indent || true
  section "This will"
  bullet "Move the Fedora/GRUB entry back to FIRST in BootOrder (Limine kept, deprioritized)"
  bullet "Optionally delete the Limine NVRAM entry, ESP files, hook + scripts, $CONFIG_FILE"
  bullet "Never touch GRUB/shim packages"
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
    # Theme assets outside EFI/limine (per-theme ESP destinations).
    run rm -rf "$esp/cachyos.png" "$esp/background.jpg" "$esp/PHXEGA8.F14" \
      "$esp/lumon-limine-theme" "$esp/limine-bg.jpeg" "$esp/splash-limine-fallout.png" \
      "$esp/rift.jpg" "$esp/spitfire.png" "$esp/archcustom.png" "$esp/squatchware-boot.png" \
      "$esp/shiro-limine" "$esp/themes/sekiro" || true
    run rm -f "$esp/limine/thinkpad-wallpaper.png" "$esp/limine/thinkpad-font.bin" || true
    run rmdir "$esp/limine" 2>/dev/null || true
    # Only remove our fallback if it is actually Limine (check size/signature loosely: keep .limine-bak files).
    warn "Leaving EFI/BOOT/BOOTX64.EFI in place unless you confirm it is Limine's (a shim backup may exist alongside)."
    if confirm "Also remove EFI/BOOT/BOOTX64.EFI fallback copy? (only if you KNOW it is Limine's)"; then
      run rm -f "$esp/EFI/BOOT/BOOTX64.EFI" || true
    fi
    run rm -f "$HOOK_FILE" /etc/kernel/install.d/94-cachyos-sign.install "$SYNC_SCRIPT" "$UPDATE_WRAPPER" "$CONFIG_FILE" "$LIMINE_TOOL" "$THEME_SNIPPET" "$STATE_FILE" || true
    snapper_suite_uninstall
    run rm -rf /etc/limine/hooks /etc/limine/entry-tool.d || true
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
  DO_MEMTEST=0; DO_SHELL=0; DO_THEME_ID="catppuccin-mocha"
  DO_CACHYOS="no"; DO_CACHYOS_INSTALL=0
  DO_SECUREBOOT="no"; SB_STATE="unknown"
  SB_KEY_DIR="$SB_KEY_DIR_DEFAULT"; SB_CN="Fedora Limine Secure Boot"
  DO_NVIDIA="skip"
  BACKUP_DEST=""

  if [[ "$MODE" == "install" || "$MODE" == "check" ]]; then
    preflight  # sets ESP (global)
  else
    banner
    is_fedora || die "This script is for Fedora only (ID=fedora in /etc/os-release)."
    detect_sb_state
  fi
  MACHINE="$(machine_id)"

  if [[ "$MODE" == "check" ]]; then
    ok "Preflight-only mode: no changes made."
    exit 0
  fi

  if [[ "$MODE" == "update" ]]; then
    log "Update mode: re-sync + regenerate (no reinstall of binaries)."
    [[ -f "$SYNC_SCRIPT" ]] || die "Not installed yet ($SYNC_SCRIPT missing). Run install mode first."
    # Filtered source: never execute stray non-assignment lines from a mangled config.
    [[ -f "$CONFIG_FILE" ]] && . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$CONFIG_FILE" 2>/dev/null || true) || true
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

  if [[ "$MODE" == "theme" ]]; then
    theme_flow "$THEME_METHOD"
    exit 0
  fi

  # ---- install wizard -------------------------------------------------------
  # Auto-detect: a previous run leaves $STATE_FILE (valid KEY="value" lines).
  if install_state_present; then
    section "Previous install detected"
    install_state_summary
    hint "Re-running the full wizard backs up and reinstalls over it."
    local prev_choice
    prev_choice="$(ask_numbered "How to proceed" \
      "Reinstall (full wizard)" \
      "Update only (re-sync kernels + regen conf)" \
      "Change boot theme" \
      "Uninstall (rollback to GRUB)" \
      "Abort (no changes)")"
    case "$prev_choice" in
      1) log "Reinstalling over previous install..." ;;
      2) log "Update mode: re-sync + regenerate (no reinstall of binaries)."
         [[ -f "$SYNC_SCRIPT" ]] || die "Not installed yet ($SYNC_SCRIPT missing)."
         [[ -f "$CONFIG_FILE" ]] && . <(grep -E '^[[:space:]]*(#|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=|$)' "$CONFIG_FILE" 2>/dev/null || true) || true
         run "$SYNC_SCRIPT" sync all
         write_install_state keep
         ok "Update complete."
         exit 0 ;;
      3) theme_flow ask; exit 0 ;;
      4) do_uninstall; exit 0 ;;
      *) die "Aborted. No changes made." ;;
    esac
  fi
  section "Install plan"
  kv "ESP" "$ESP"
  kv "machine-id" "$MACHINE"
  local plan_i=1 plan_step
  for plan_step in \
    "Backup" \
    "Dependencies (+ optional CachyOS kernel)" \
    "Download Limine" \
    "Deploy EFI" \
    "Config + kernel-install hook" \
    "Boot theme" \
    "Sync kernels to the ESP" \
    "NVRAM entry (Limine first, GRUB kept)" \
    "Optional extras (memtest, shell, snapshots)" \
    "Verify"; do
    printf '  %s%2d.%s %s\n' "$C_CYN$C_BLD" "$plan_i" "$C_RST" "$plan_step"
    plan_i=$((plan_i + 1))
  done
  hint "Secure Boot signing runs as an extra step if you enable it below."
  hint "GRUB is NEVER removed automatically."
  confirm "Start the install?" || die "Aborted. No changes made."

  # Basic choices up front (idiot-proof defaults).
  if [[ "$ASSUME_YES" -eq 0 ]]; then section "Install options"; fi
  r="$(ask_yes_no "Install fallback EFI/BOOT/BOOTX64.EFI copy?" "yes")"; [[ "$r" == "yes" ]] && DO_FALLBACK=1 || DO_FALLBACK=0
  r="$(ask_yes_no "Create 'Limine' NVRAM entry + put it first?" "yes")"; [[ "$r" == "yes" ]] && DO_EFIBOOTMGR=1 || DO_EFIBOOTMGR=0
  r="$(ask_yes_no "Auto-add Windows/other EFI entries if found?" "yes")"; [[ "$r" == "yes" ]] && DO_DUALBOOT_SCAN=1 || DO_DUALBOOT_SCAN=0
  if [[ "$(firmware_type)" == "bios" ]]; then
    r="$(ask_yes_no "Also do BIOS (limine bios-install) stage?" "no")"; [[ "$r" == "yes" ]] && DO_BIOS=1 || DO_BIOS=0
  else
    DO_BIOS=0
  fi

  extras_menu  # sets DO_MEMTEST/DO_SHELL/DO_SNAPSHOTS(auto/no)

  theme_menu  # sets DO_THEME_ID (boot theme catalog selection)

  cachyos_install_menu  # sets DO_CACHYOS_INSTALL (0/1) + DO_CACHYOS (yes/no); may pre-seed DO_SECUREBOOT

  secureboot_menu  # sets DO_SECUREBOOT (no|mok-shim|custom-db); never enrolls here

  # Hard block: Secure Boot enabled but user declined signing.
  # Unsigned Limine cannot boot with SB on — abort rather than silently
  # creating a non-booting NVRAM entry.
  if [[ "$SB_STATE" == "enabled" && "$DO_SECUREBOOT" == "no" ]]; then
    die "Secure Boot is ENABLED but you declined Secure Boot setup.

Unsigned Limine cannot boot with Secure Boot on — your firmware will
reject limine_x64.efi before it even starts. GRUB (shimx64.efi) is
Microsoft-signed and keeps working, but Limine will not boot.

Options:
  1. Disable Secure Boot in your firmware/BIOS setup, then re-run this script.
  2. Re-run with:  sudo $0 --sb-setup=mok-shim   (recommended, keeps SB on)
  3. Re-run with:  sudo $0 --sb-setup=custom-db  (advanced, Setup Mode db)

GRUB is untouched and remains bootable. No Limine changes were made."
  fi

  phase 1 10 "Backup"
  do_backup
  phase 2 10 "Dependencies"
  install_deps
  install_cachyos_kernel  # COPR enable + dnf install (before sync so ESP picks it up)

  phase 3 10 "Download Limine"
  LIMINE_VER="$(limine_version_menu)"
  if [[ "$LIMINE_VER" == "latest" ]]; then
    LIMINE_VER="$(latest_limine_version)"
    log "Latest Limine: $LIMINE_VER"
  fi
  WORKDIR="$(mktemp -d /tmp/fedora-limine-XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$WORKDIR'" EXIT
  fetch_limine "$LIMINE_VER" "$WORKDIR"

  phase 4 10 "Deploy EFI"
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

  phase 5 10 "Config + kernel-install hook"
  write_default_config
  install_hook_and_sync_script
  # Theme before the kernel sync so the generated limine.conf carries it.
  # A failed theme download never aborts the install (falls back to none).
  phase 6 10 "Boot theme"
  fetch_theme "$DO_THEME_ID" "$ESP" || {
    warn "Continuing without theme visuals."
    config_set_key "$CONFIG_FILE" "THEME_NAME" "none" || true
  }
  phase 7 10 "Sync kernels to the ESP"
  sync_all_kernels
  phase 8 10 "NVRAM entry (Limine first, GRUB kept)"
  register_efibootmgr "$ESP"
  phase 9 10 "Optional extras"
  # extras need 0/1 ints; DO_SNAPSHOTS currently "auto"/"no" -> map back for installer.
  if [[ "$DO_SNAPSHOTS" == "auto" ]]; then DO_SNAPSHOTS=1; else DO_SNAPSHOTS=0; fi
  install_extras "$ESP"
  if [[ "$DO_SECUREBOOT" != "no" ]]; then
    phase "-" 10 "Secure Boot setup"
    # Re-read key dir (existing config may define a custom one we kept).
    SB_KEYS="$(grep '^SB_KEY_DIR=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || true)"
    [[ -z "${SB_KEYS:-}" ]] && SB_KEYS="$SB_KEY_DIR"
    case "$DO_SECUREBOOT" in
      mok-shim) sb_setup_mok "$ESP" ;;
      custom-db) sb_setup_db "$ESP" ;;
    esac
  fi
  phase 10 10 "Verify"
  verify_install "$ESP"
  write_install_state "$LIMINE_VER"
  print_next_steps
}

main "$@"

# Fedora → Limine Switcher (CachyOS-style suite)

One interactive script to replace GRUB with **Limine** on Fedora — idiot-proof,
undoable, and keeping GRUB as a fallback until you're sure.

Tested on: Fedora 41/42/43/45, x86_64, UEFI. Your machine (Fedora 45 prerelease,
4 GB ESP at `/boot/efi`, Secure Boot disabled, XFS root) is the ideal case.

## 30-second start

```bash
cd ~/Github/fedora-limine-switch
sudo ./fedora-limine-switch.sh            # interactive wizard (recommended)
```

Other modes:

```bash
sudo ./fedora-limine-switch.sh --check     # preflight only, changes nothing
sudo ./fedora-limine-switch.sh --update    # re-sync kernels + regenerate limine.conf
sudo ./fedora-limine-switch.sh --uninstall # rollback to GRUB-first
sudo ./fedora-limine-switch.sh --sb-setup  # add Secure Boot signing (opt-in, see below)
sudo ./fedora-limine-switch.sh --sb-status # report Secure Boot state, no changes
sudo ./fedora-limine-switch.sh --sb-resign # re-enroll conf hash + re-sign EFIs
sudo ./fedora-limine-switch.sh --yes       # non-interactive (never enrolls SB keys)
sudo ./fedora-limine-switch.sh --dry-run   # print what WOULD happen
```

After install: **reboot → Limine boots first → test every kernel → keep GRUB
until proven**. Rollback is one command (see below).

## What you get (CachyOS parity)

| CachyOS (Arch) | This project (Fedora) | Notes |
|---|---|---|
| `limine` package | Official `limine-binary.tar.xz` from GitHub releases (default: latest, fallback `12.9.3`) → `EFI/limine/limine_x64.efi` + optional `EFI/BOOT/BOOTX64.EFI` | No Fedora package exists; binary tarball is 860 KB, GPG-signed upstream |
| `limine` CLI (`bios-install`, `enroll-config`) | Built via `make` from the same tarball | Needed for BIOS path + Secure Boot hash enrollment |
| `limine-mkinitcpio-hook` / `limine-dracut-support` + pacman hooks | `95-limine.install` (kernel-install plugin) + `limine-fedora-sync` + `limine-update` wrapper | Runs **after** `50-dracut`, so initramfs exists; fires on every `dnf install/remove kernel*` |
| `limine-entry-tool --add-kernel` layout `$ESP/<machine-id>/<kernel>/` | Same layout | FAT-safe; Limine reads **only FAT12/16/32 + ISO9660**, never ext4/xfs/btrfs |
| `/etc/default/limine` knobs | `/etc/default/limine` (same key names where possible) | Edit `KERNEL_CMDLINE`/`TIMEOUT`, then `sudo limine-update` |
| `FIND_BOOTLOADERS=yes` (Windows scan) | Same (checks `EFI/Microsoft/Boot/bootmgfw.efi`) | + memtest86+ / EDK2 Shell auto-entries if present on ESP |
| `ENABLE_UKI`, fallback images | Rescue entry (`vmlinuz-0-rescue` + `initramfs-0-rescue`) | Fedora has no `-fallback` mkinitcpio image; rescue fills that role |
| `amd-ucode` / `intel-ucode` separate `module_path` | **Not needed** — Fedora `dracut` embeds early microcode *inside* `initramfs-*.img` (`early_microcode=yes`) | Nothing to copy |
| `limine-snapper-sync` + overlayfs | Minimal: includes `$ESP/limine-snapshots.conf` if you create it; full auto-sync has no Fedora port yet | Only activates on BTRFS + snapper (your XFS root skips it) |
| `sbctl` signing + `enroll-config` | Opt-in Secure Boot: MOK/shim (recommended) or custom-db, with `enroll-config` + per-file `#<b2sum>` hashes, auto re-signed on every kernel update | Off by default; `--yes` never enrolls keys (needs reboot + password) |
| — (Arch has no DKMS-by-default story) | Opt-in NVIDIA/DKMS unification: one MOK signs Limine + `nvidia*.ko` (+ WiFi DKMS), rebuild for all kernels, ESP re-sync hook for DKMS rebuilds | See "NVIDIA + Secure Boot" below |
| Catppuccin theme + splash | Same palette defaults; optional `/boot/limine-splash.png` | `WALLPAPER=` in config |
| `memtest86+`, EDK2 Shell | Optional `memtest86+` → `EFI/memtest86+/memtest86x64.efi`, `edk2-shell-x64` → `EFI/tools/Shell.efi` | Correct Fedora package names (not `-efi` / bare) |

## How it works

```
dnf installs kernel-core
  └─> /bin/kernel-install add <ver> /lib/modules/<ver>/vmlinuz
        ├─> 50-dracut.install        builds /boot/initramfs-<ver>.img
        ├─> 20-grub.install          writes BLS entry (kept, harmless)
        └─> 95-limine.install  (ours, runs LAST)
              └─> limine-fedora-sync sync <ver>
                    ├─> cp /boot/vmlinuz-* + initramfs-*.img
                    │       → $ESP/<machine-id>/<ver>/   (FAT-readable)
                    └─> regenerate limine.conf ×3 locations:
                        $ESP/limine.conf
                        $ESP/EFI/limine/limine.conf   (Limine searches here first)
                        $ESP/EFI/BOOT/limine.conf
```

NVRAM: `efibootmgr -c -L Limine -l '\EFI\limine\limine_x64.efi'` then
`BootOrder` = `Limine,OldEntries...`. The old `Fedora` (shim→GRUB) entry is
**kept**. Rollback = reorder back.

Backups go to `/root/fedora-limine-backup/<timestamp>/`
(`efibootmgr -v`, `/etc/default/grub`, ESP `EFI/` tarball, BLS copies).
Log: `/var/log/fedora-limine-switch.log`.

## Requirements

- Fedora (any recent), x86_64, root (`sudo`).
- UEFI recommended. BIOS works but needs a `bios_grub`/`ef02` partition and
  manual disk selection — the script walks you through it.
- ESP mounted at `/boot/efi` (or `/efi`), **vfat**, with free space ≥
  `sum(vmlinuz + initramfs) + 60 MB`. Your 4 GB ESP is plenty; stock 600 MB
  ESPs fit ~2 kernels — set `installonly_limit=2` in `/etc/dnf/dnf.conf` if tight.
- Internet (to fetch Limine from GitHub). No build toolchain needed for
  UEFI-only (only `gcc`+`make` for the tiny `limine` host tool).

Installed deps (required): `efibootmgr dosfstools mtools curl tar gzip xz gawk
coreutils grep sed binutils mokutil parted btrfs-progs gcc make`.
Optional (failures tolerated): `os-prober sbsigntools openssl memtest86+
edk2-shell-x64 snapper python3`.

Installed deps (required): `efibootmgr dosfstools mtools curl tar gzip xz gawk
coreutils grep sed binutils mokutil parted btrfs-progs gcc make`.
Optional (failures tolerated): `os-prober sbsigntools openssl memtest86+
edk2-shell-x64 snapper python3`.
Secure Boot setup installs on demand: `sbsigntools openssl mokutil`
(+ `efitools` for the custom-db method).

## Secure Boot (opt-in)

You have it **disabled** (`mokutil --sb-state` → `SecureBoot disabled`), so
Limine boots unsigned and there is nothing to do. If you turn Secure Boot on
(or it already is), pick **one** method in the wizard — or later via
`--sb-setup`. Upstream Limine is not Microsoft-signed, so you sign it with
your own key. Enrolling the `limine.conf` hash (`limine enroll-config`) is
the explicit opt-in to hardening: config verified every boot, all
kernel/initramfs paths require `#<b2sum>` suffixes, editor disabled.
EFI chainloads (Windows, memtest, EDK2 Shell) stay hash-free — firmware
verifies those.

| Method | Firmware steps | Boot path with SB on | For whom |
|---|---|---|---|
| `mok-shim` (recommended) | One MokManager screen on next boot (set a password, enroll MOK) | firmware → `shimx64.efi` (MS-signed) → `grubx64.efi` (= your signed Limine) → kernels (hash-verified) | Everyone on Fedora; no Setup Mode |
| `custom-db` (advanced) | Firmware Setup Mode + enroll key into `db` | firmware → Limine directly, no shim | Shim-free purists |

What the script does for either method (idempotent, re-runnable):

1. Generates a keypair in `/etc/limine/keys/` (`MOK.{priv,pem,der}`, 2048-bit,
   100-year) unless one exists. Keys never leave that dir.
2. Sets `/etc/default/limine`: `SECURE_BOOT=<method>`,
   `ENABLE_VERIFICATION=yes`, `ENABLE_ENROLL_CONFIG=yes`.
3. Re-syncs kernels (hashes appended), bakes `b2sum(limine.conf)` into each
   managed EFI (`EFI/limine/limine_x64.efi`, fallback `EFI/BOOT/BOOTX64.EFI`),
   and signs them (`sbsign` + `sbverify`).
4. `mok-shim` only: backs up real GRUB to
   `EFI/fedora/grubx64.efi.grub-bak` and places signed Limine as
   `EFI/fedora/grubx64.efi`, then runs `mokutil --import <key>.der`.
5. Every later kernel/conf update re-enrolls + re-signs automatically inside
   `limine-fedora-sync` (the hook never fails the boot update: it warns and
   continues if keys/tools are missing).

Your part:

- `mok-shim`: on the next boot, complete the blue MokManager screen (Enroll
  MOK → Continue → Yes → password → Reboot), then boot the **Fedora (shim)**
  entry. The direct `Limine` entry works with SB off.
- `custom-db`: follow the printed Setup Mode + `efi-updatevar` steps, then
  `sudo ./fedora-limine-switch.sh --sb-resign`.

Useful commands:

```bash
sudo ./fedora-limine-switch.sh --sb-status  # firmware state, key presence,
                                            # signature validity, hashed paths
sudo ./fedora-limine-switch.sh --sb-resign  # after manual conf/key changes
sbverify --cert /etc/limine/keys/MOK.pem /boot/efi/EFI/limine/limine_x64.efi
mokutil --list-enrolled | grep -i limine
```

Notes:

- `--yes` never enrolls keys (MOK import needs a password + reboot). Run
  `--sb-setup` interactively when ready.
- A `dnf update grub2` can restore the real `grubx64.efi` over the shim copy;
  re-run `--sb-resign` (redeploys + re-signs) if that happens.
- Uninstall offers to restore real GRUB from `.grub-bak`. Enrolled MOKs are
  left alone (harmless); `mokutil --reset` removes them if you insist.
- BIOS systems skip Secure Boot entirely (UEFI-only).

## NVIDIA + Secure Boot (opt-in, part of SB setup)

Verified on this machine: RTX 5070 Ti (Blackwell — open modules mandatory),
driver 615.78.08 via NVIDIA `.run` + DKMS for 3+ kernels, modules signed by
an unenrolled `CN=DKMS module signing key`, WiFi (`mt7927`) on the same DKMS
key. SB off today, so everything works; enabling SB without fixing this =
black screen + dead WiFi (lockdown `integrity` rejects the modules).

One MOK covers both jobs (shim trusts it for EFI binaries, the kernel adds
it to the `.machine` keyring for modules), so the script unifies DKMS onto
your Limine MOK instead of enrolling twice:

1. `sb-setup` detects NVIDIA/DKMS and offers unification (default yes).
2. `/etc/dkms/framework.conf` gets (backed up first, idempotent marker):
   `mok_signing_key="/etc/limine/keys/MOK.priv"`,
   `mok_certificate="/etc/limine/keys/MOK.pem"`.
3. `dkms autoinstall -k <each installed kernel>` rebuilds **only** kernels
   whose `nvidia.ko` is missing or signed by the old key; 7.2.10 kernels
   with no modules yet get built as a side effect.
4. An ESP re-sync line is appended to DKMS `post_transaction` (backed up,
   idempotent): DKMS dracut regens bypass `kernel-install`, so without this
   Limine would serve a stale initramfs after every driver rebuild.
5. The single `mokutil --import` (same reboot as Limine) enrolls the one key
   for EFI + modules + WiFi.

RPM Fusion `akmod-nvidia` users (open flavor is default there, incl.
Blackwell): unification doesn't apply — the script instead offers to enroll
`/etc/pki/akmods/certs/public_key.der` in the same MokManager session.
Migrating `.run`→RPM Fusion is **not** recommended mid-setup (requires full
`.run` uninstall first).

Facts worth knowing:

- GSP firmware blobs need no signing (firmware isn't module-checked).
- `nvidia-drm modeset/fbdev` already default to `Y` on 615 — no cmdline needed.
- Suspend-to-RAM is lockdown-safe; hibernate-to-disk is refused under
  lockdown integrity (moot here: zram-only swap, `resume=0:0`).
- No LUKS volumes → no TPM resealing when SB flips.
- CachyOS kernels are **unsigned** (`sbverify: No signature table present`;
  Fedora kernels carry the fedoraca signature). Under SB, the CachyOS kernel
  boots **only** via Limine (hash-verified); the GRUB/shim fallback path
  enforces kernel signatures and will refuse it. Fedora kernels boot either way.

Diagnose: `modinfo -F signer nvidia`, `mokutil --test-key <key.der>`
(parse the text — exit code is always 0), `dmesg | grep -iE 'lockdown|key.*reject'`,
per-kernel signers in `--sb-status`. After any driver update: nothing to do
(hook re-syncs ESP); if display breaks, `--sb-status` then `--sb-resign`.

## Snapshots (BTRFS only)

Your root is XFS, so this section doesn't apply to you — the script detects
that and skips. On BTRFS + snapper systems:

1. `dnf install snapper btrfs-progs inotify-tools` (script offers this).
2. Create a snapper config for `/`.
3. Write snapshot entries to `/boot/efi/limine-snapshots.conf` in
   `limine.conf` fragment syntax (see CachyOS `limine-snapper-sync` README
   for the format), then `sudo limine-update` picks it up under `//Snapshots`.
4. Full CachyOS-style auto-generation (`limine-snapper-sync.service` +
   overlayfs-writable boots) has no Fedora port yet — contributions welcome.

## Removing GRUB (only when Limine is proven!)

The script **never** does this automatically. When every Limine entry boots:

```bash
# 1. Prove Limine boots alone: set it first, reboot twice, test all kernels.
efibootmgr -v

# 2. (Optional) Remove GRUB packages. Note protected + dependents!
sudo rm -f /etc/dnf/protected.d/grub2-efi-x64.conf /etc/dnf/protected.d/shim.conf  # if present
sudo dnf remove grub2-efi-x64 grub2-common grub2-tools grub2-tools-minimal
# KEEP shim-x64 + efibootmgr + mokutil unless you know why you're removing them.
# KEEP grubby (tiny; akmods/systemd-udev may depend on it).

# 3. Delete the stale Fedora NVRAM entry + ESP dir (only now!):
sudo efibootmgr -b <FEDORA-NUM> -B
# sudo rm -rf /boot/efi/EFI/fedora   # only after Limine boots reliably
```

If anything breaks: firmware boot menu → pick `Fedora` (if you kept it), or
`sudo ./fedora-limine-switch.sh --uninstall`.

## Troubleshooting

- **No `Limine` in firmware boot menu**: NVRAM write failed (VM without
  efivars?). Use the fallback: firmware → boot `UEFI OS` / `EFI/BOOT/BOOTX64.EFI`,
  or firmware setup → add `\EFI\limine\limine_x64.efi` manually.
- **`limine.conf` empty / `no-kernels-found`**: run `sudo kernel-install add-all`
  then `sudo limine-update`. Check `/boot/vmlinuz-*` exists.
- **Out of ESP space**: `sudo dnf remove --oldinstallonly --setopt installonly_limit=2 kernel`,
  or raise `installonly_limit` discipline. Never delete the running kernel.
- **Boots to black / wrong root**: compare `cat /proc/cmdline` (when booted
  via GRUB) with `KERNEL_CMDLINE=` in `/etc/default/limine`. Fix `root=UUID=…`
  there, `sudo limine-update`, reboot.
- **SELinux denials**: script runs `restorecon -R` after copies. If you copy
  manually, repeat it.
- **CachyOS kernel on Fedora** (like your `7.2.9-cachyos1.fc45`): works fine —
  it's still `/boot/vmlinuz-*` + dracut initramfs. The script treats all
  versions generically.
- **Two `Fedora` NVRAM entries on different disks** (you have `nvme0n1p1` +
  `nvme2n1p1`): the script targets the ESP mounted at `/boot/efi`. Old-disk
  entries are left alone — clean them with `efibootmgr -b <NUM> -B` once sure.
- **Secure Boot rejects Limine / config panic**: boot the `Fedora` (shim/GRUB)
  entry, then `sudo ./fedora-limine-switch.sh --sb-status`. Common causes:
  missed MokManager enrollment (re-run `mokutil --import`), stale conf hash
  (run `--sb-resign`), or a `grub2` update overwrote the shim copy (re-run
  `--sb-resign` to redeploy + re-sign).
- **Log**: `/var/log/fedora-limine-switch.log`. **Backups**:
  `/root/fedora-limine-backup/<timestamp>/`.

## Files installed

- `/etc/default/limine` — your settings (edit + `sudo limine-update`).
- `/etc/kernel/install.d/95-limine.install` — kernel-install plugin.
- `/usr/local/sbin/limine-fedora-sync` — ESP sync + `limine.conf` generator
  (hashes + re-enroll/re-sign when Secure Boot is configured).
- `/usr/local/sbin/limine-update` — `sync all` wrapper (CachyOS parity).
- `/usr/local/bin/limine` — upstream host tool (`bios-install`, `enroll-config`).
- `/etc/limine/keys/MOK.{priv,pem,der}` — your Secure Boot key (only with `--sb-setup`).
- `/etc/dkms/framework.conf.limine-bak-*` — pre-unification DKMS backup (only with NVIDIA step).
- `$ESP/EFI/limine/limine_x64.efi`, `$ESP/<machine-id>/<ver>/…`,
  `$ESP/limine.conf` (+ copies under `EFI/limine/`, `EFI/BOOT/`).

## Uninstall / rollback

```bash
sudo ./fedora-limine-switch.sh --uninstall
```

Puts `Fedora`/GRUB first again, optionally deletes the Limine NVRAM entry,
ESP files, hook, scripts, and config. GRUB/shim RPMs are never touched.

## Sources

- Limine upstream (`USAGE.md`, `CONFIG.md`, `INSTALL.md`, `FAQ.md`):
  <https://github.com/Limine-Bootloader/Limine>
- Release used by default (auto-detected, fallback `v12.9.3`):
  <https://github.com/Limine-Bootloader/Limine/releases>
- CachyOS suite design (entry tool + snapper sync):
  <https://gitlab.com/Zesko/limine-entry-tool>
  <https://gitlab.com/Zesko/limine-snapper-sync>
  <https://wiki.cachyos.org/configuration/boot_manager_configuration>
- Fedora boot stack: `man kernel-install`, `/usr/lib/kernel/install.d/`,
  `/usr/lib/dracut/dracut.conf.d/01-dist.conf`, `efibootmgr(8)`.

# CachyOS parity

CachyOS ships the best-in-class Limine setup. This table maps every feature
of that suite to its Fedora equivalent here — useful if you're switching
distros and wondering where something went.

| CachyOS (Arch) | Here (Fedora) | Notes |
|---|---|---|
| `limine` package | Official `limine-binary.tar.xz` from GitHub (latest, fallback `12.9.3`) → `EFI/limine/limine_x64.efi` + optional `EFI/BOOT/BOOTX64.EFI` | Fedora has no Limine package. The tarball is 860 KB and GPG-signed upstream |
| `limine` CLI (`bios-install`, `enroll-config`) | Built with `make` from that same tarball | Needed for BIOS installs and Secure Boot hash enrollment |
| `limine-mkinitcpio-hook` / `limine-dracut-support` + pacman hooks | `95-limine.install` (kernel-install plugin) + `limine-fedora-sync` + `limine-update` | Runs after `50-dracut`, so the initramfs already exists. Fires on every `dnf install/remove kernel*` |
| `limine-entry-tool` layout `$ESP/<machine-id>/<kernel>/` | Same layout | FAT-safe. Limine only reads FAT12/16/32 and ISO9660 — never ext4/xfs/btrfs |
| `/etc/default/limine` knobs | Same file, same key names where possible | Edit `KERNEL_CMDLINE` or `TIMEOUT`, then `sudo limine-update` |
| `FIND_BOOTLOADERS=yes` (Windows scan) | Same (checks `EFI/Microsoft/Boot/bootmgfw.efi`) | Also auto-adds memtest86+ / EDK2 Shell entries if they're on the ESP |
| `ENABLE_UKI`, fallback images | Rescue entry (`vmlinuz-0-rescue` + `initramfs-0-rescue`) | Fedora's dracut has no `-fallback` image, so the rescue entry fills that role |
| `amd-ucode` / `intel-ucode` as separate `module_path` | Not needed | Fedora's dracut already embeds early microcode inside `initramfs-*.img` (`early_microcode=yes`) |
| `limine-snapper-sync` + overlayfs | Minimal: includes `$ESP/limine-snapshots.conf` if you create it | Full auto-sync has no Fedora port yet. See [Snapshots](snapshots.md) |
| `sbctl` signing + `enroll-config` | Opt-in Secure Boot: MOK/shim (recommended) or custom-db, with `enroll-config`, per-file `#<b2sum>` hashes, re-signed on every kernel update | Off by default. See [Secure Boot](secure-boot.md) |
| — (Arch doesn't do DKMS by default) | Opt-in NVIDIA/DKMS unification: one MOK signs Limine, `nvidia*.ko`, and WiFi DKMS modules | See [NVIDIA + Secure Boot](nvidia-secure-boot.md) |
| Catppuccin theme + splash | Same palette defaults, optional `/boot/limine-splash.png` | Set `WALLPAPER=` in the config |
| `memtest86+`, EDK2 Shell | Optional `memtest86+` → `EFI/memtest86+/memtest86x64.efi`, `edk2-shell-x64` → `EFI/tools/Shell.efi` | Fedora's package names differ from Arch's |

# Fedora → Limine Switcher

One script that swaps GRUB for [Limine](https://github.com/Limine-Bootloader/Limine) on Fedora.

GRUB stays installed and bootable the entire time, so you always have a way
back. Tested on Fedora 41–45, x86_64, UEFI.

## Install

```bash
git clone https://github.com/ryzendew/fedora-limine-switch.git
cd fedora-limine-switch
sudo ./fedora-limine-switch.sh
```

That's the wizard. It checks your system first, tells you what it's about to
do, and asks before touching anything.

**After it finishes, reboot and test it properly:**

1. At the firmware boot menu, choose **Limine** (or let the timer run out).
2. Boot every kernel entry once. Boot the rescue entry too if you keep one.
3. Leave GRUB alone until Limine has been solid for a few days.

**If it doesn't boot:** reboot, pick **Fedora** from the firmware boot menu,
then run:

```bash
sudo ./fedora-limine-switch.sh --uninstall
```

That puts GRUB back in charge. Nothing else is lost.

## Other commands

| Command | What it does |
|---|---|
| `--check` | Checks your system, changes nothing |
| `--dry-run` | Prints what would happen |
| `--update` | Re-syncs kernels and rewrites `limine.conf` (run this after editing `/etc/default/limine`) |
| `--uninstall` | Rolls back to GRUB-first |
| `--sb-setup` | Secure Boot signing setup (opt-in) |
| `--sb-status` | Reports Secure Boot state, changes nothing |
| `--sb-resign` | Re-signs everything after a conf or key change |
| `--yes` | Non-interactive mode (never enrolls Secure Boot keys) |

Every command runs with `sudo`.

## Requirements

- Fedora, x86_64, root access.
- UEFI recommended. BIOS works but needs an `ef02` partition — the script
  walks you through it.
- ESP mounted at `/boot/efi` (or `/efi`), vfat, with room for your kernels
  plus 60 MB. A stock 600 MB ESP holds about two kernels — set
  `installonly_limit=2` in `/etc/dnf/dnf.conf` if space is tight.
- Internet once, to download Limine.

It installs these if they're missing:

```
efibootmgr dosfstools mtools curl tar gzip xz gawk coreutils grep sed
binutils mokutil parted btrfs-progs gcc make
```

Optional packages (`os-prober sbsigntools openssl memtest86+ edk2-shell-x64
snapper python3`) are used when present and skipped when not.

## Documentation

| Doc | What's in it |
|---|---|
| [How it works](docs/architecture.md) | The boot chain, files it installs, backups and logs |
| [CachyOS parity](docs/cachyos-parity.md) | How this compares to the CachyOS Limine suite |
| [Secure Boot](docs/secure-boot.md) | Signing Limine — only needed if Secure Boot is on |
| [NVIDIA + Secure Boot](docs/nvidia-secure-boot.md) | Getting signed NVIDIA/DKMS modules working |
| [Snapshots](docs/snapshots.md) | Boot menu entries for BTRFS snapper snapshots |
| [Removing GRUB](docs/removing-grub.md) | Deleting GRUB for good — only once Limine is proven |
| [Uninstall / rollback](docs/uninstall.md) | Going back to GRUB |
| [Troubleshooting](docs/troubleshooting.md) | When something's wrong |

## Sources

- Limine upstream docs: <https://github.com/Limine-Bootloader/Limine>
- Limine releases (latest used, fallback `v12.9.3`):
  <https://github.com/Limine-Bootloader/Limine/releases>
- CachyOS suite this is modeled on:
  <https://gitlab.com/Zesko/limine-entry-tool>
  <https://gitlab.com/Zesko/limine-snapper-sync>
  <https://wiki.cachyos.org/configuration/boot_manager_configuration>
- Fedora boot stack: `man kernel-install`, `/usr/lib/kernel/install.d/`,
  `efibootmgr(8)`

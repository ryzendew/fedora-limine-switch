# How it works

The short version: every time `dnf` installs a kernel, Fedora's
`kernel-install` runs a chain of hooks. We drop in a hook that runs last and
copies the new kernel somewhere Limine can actually read it.

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

Why copy to the ESP? Limine can only read FAT and ISO9660 filesystems — it
cannot read your ext4/xfs/btrfs root. Fedora keeps kernels on the root
filesystem, so they have to be copied to the ESP.

## Boot order

The script creates a `Limine` entry with `efibootmgr` and puts it first in
the boot order:

```
BootOrder: Limine, Fedora, ...
```

The old `Fedora` entry (shim → GRUB) is left alone, so it stays as your
fallback. Rolling back just means putting it back first.

## Backups and logs

Everything the script touches gets backed up first:

- Backups: `/root/fedora-limine-backup/<timestamp>/`
  (boot order, GRUB config, a tarball of the ESP, BLS entries)
- Log: `/var/log/fedora-limine-switch.log` — check this first if something
  goes wrong

## Files it installs

| Path | Purpose |
|---|---|
| `/etc/default/limine` | Your settings. Edit it, then run `sudo limine-update` |
| `/etc/kernel/install.d/95-limine.install` | The hook that fires on every kernel install |
| `/usr/local/sbin/limine-fedora-sync` | Copies kernels to the ESP and writes `limine.conf` |
| `/usr/local/sbin/limine-update` | Re-syncs every kernel (run this after config changes) |
| `/usr/local/bin/limine` | The upstream Limine tool (`bios-install`, `enroll-config`) |
| `/etc/limine/keys/MOK.{priv,pem,der}` | Your Secure Boot key (only if you ran `--sb-setup`) |
| `/etc/dkms/framework.conf.limine-bak-*` | DKMS backup (only if you ran the NVIDIA step) |
| `$ESP/EFI/limine/limine_x64.efi` | Limine itself |
| `$ESP/<machine-id>/<kernel>/` | Copied kernels + initramfs images |
| `$ESP/limine.conf` | The boot menu config (+ copies under `EFI/limine/`, `EFI/BOOT/`) |

# Troubleshooting

Start with the log — it answers most questions:

```bash
less /var/log/fedora-limine-switch.log
```

Backups from the last run are in `/root/fedora-limine-backup/<timestamp>/`.

## Symptoms

### No `Limine` in the firmware boot menu

The NVRAM entry didn't get written — common in VMs where efivars aren't
available. Work around it with the fallback file:

- Boot `UEFI OS` from the firmware menu (that's `EFI/BOOT/BOOTX64.EFI`), or
- In firmware setup, add `\EFI\limine\limine_x64.efi` as a boot entry manually.

### `limine.conf` says `no-kernels-found`

```bash
sudo kernel-install add-all
sudo limine-update
```

If that doesn't help, confirm kernels exist: `ls /boot/vmlinuz-*`.

### Out of ESP space

```bash
sudo dnf remove --oldinstallonly --setopt installonly_limit=2 kernel
```

**Never delete the running kernel.** Check which one that is with
`uname -r` first.

### Boots to a black screen, or root filesystem not found

Your kernel command line doesn't match. When booted via GRUB, grab the good
one:

```bash
cat /proc/cmdline
```

Compare it with `KERNEL_CMDLINE=` in `/etc/default/limine`, fix the
`root=UUID=…` part, then:

```bash
sudo limine-update
```

Reboot and try again.

### SELinux denials

The script runs `restorecon -R` after every copy. If you copied files to the
ESP by hand, run it yourself:

```bash
sudo restorecon -R /boot/efi
```

### CachyOS kernel won't boot (e.g. `7.2.9-cachyos1.fc45`)

It should — it's still a normal `/boot/vmlinuz-*` plus a dracut initramfs,
and the script treats all kernel versions the same. Check the entry's
`image_path` and `initrd_path` in `$ESP/EFI/limine/limine.conf` actually
point at files that exist.

### Two `Fedora` entries in the boot menu

You installed Fedora on more than one disk. The script only manages the ESP
mounted at `/boot/efi` and leaves the others alone. Once Limine is solid,
delete the stale ones yourself:

```bash
efibootmgr -v
sudo efibootmgr -b <NUM> -B
```

### Secure Boot rejects Limine, or the config panics

1. Boot the **Fedora** (shim/GRUB) entry so you have a working system.
2. Run `sudo ./fedora-limine-switch.sh --sb-status`.
3. Fix whichever applies:
   - MokManager enrollment never finished → `mokutil --import /etc/limine/keys/MOK.der`
   - Stale config hash → `sudo ./fedora-limine-switch.sh --sb-resign`
   - A `grub2` update overwrote the shim copy → `sudo ./fedora-limine-switch.sh --sb-resign`

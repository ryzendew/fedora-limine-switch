# Removing GRUB

**Don't do this until Limine has proven itself.** The script will never do
it for you. Wait until every Limine entry has booted cleanly, twice, across
reboots — then come back.

## 1. Confirm Limine really is first

```bash
efibootmgr -v
```

Reboot twice. Test every kernel entry. Only continue if all of them work.

## 2. Remove the GRUB packages (optional)

```bash
sudo rm -f /etc/dnf/protected.d/grub2-efi-x64.conf /etc/dnf/protected.d/shim.conf
sudo dnf remove grub2-efi-x64 grub2-common grub2-tools grub2-tools-minimal
```

**Keep these** unless you know exactly why you're removing them:

- `shim-x64`, `efibootmgr`, `mokutil` — your Secure Boot path and recovery
  tools depend on them.
- `grubby` — tiny, and akmods/systemd-udev may need it.

## 3. Clean up the old boot entry (only now)

```bash
efibootmgr -v                          # find the Fedora entry's number
sudo efibootmgr -b <FEDORA-NUM> -B     # delete it
```

Deleting the ESP directory is optional and final:

```bash
# sudo rm -rf /boot/efi/EFI/fedora     # only if Limine boots reliably
```

## If anything breaks

Reboot into the firmware boot menu and pick **Fedora** (if you kept it), or
see [Uninstall / rollback](uninstall.md).

# Uninstall / rollback

One command:

```bash
sudo ./fedora-limine-switch.sh --uninstall
```

It puts Fedora/GRUB first in the boot order again, then asks whether you
want to go further and remove the Limine NVRAM entry, ESP files, hook,
scripts, and config. It never touches GRUB or shim packages, so you can't
brick yourself with it.

If you deleted GRUB entirely before rolling back, see
[Removing GRUB](removing-grub.md) for how to get it back.

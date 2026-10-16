# Snapshots (BTRFS only)

**Only applies if your root filesystem is BTRFS.** The script checks and
quietly skips this section on XFS or ext4.

To get snapper snapshots in the Limine boot menu:

1. Install what's needed (the script offers this):
   ```bash
   sudo dnf install snapper btrfs-progs inotify-tools
   ```
2. Create a snapper config for `/`:
   ```bash
   sudo snapper -c root create-config /
   ```
3. Write snapshot entries to `/boot/efi/limine-snapshots.conf` using the
   fragment format from the
   [CachyOS limine-snapper-sync README](https://gitlab.com/Zesko/limine-snapper-sync).
4. Rebuild the menu:
   ```bash
   sudo limine-update
   ```
   Your entries show up under `//Snapshots`.

Automatic snapshot-entry generation (CachyOS's `limine-snapper-sync.service`)
has no Fedora port yet. Contributions welcome.

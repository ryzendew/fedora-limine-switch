# Secure Boot

**Do you need this?** Check:

```bash
mokutil --sb-state
```

- Says `SecureBoot disabled`? You're done. Close this page.
- Says `SecureBoot enabled`? Limine isn't signed yet and won't boot. Keep reading.

Limine isn't signed by Microsoft, so you sign it with your own key. The
wizard can do all of this for you — pick a method when it asks, or run
`sudo ./fedora-limine-switch.sh --sb-setup` later.

## Which method?

| Method | What you'll do at next boot | Boot path | Choose this if... |
|---|---|---|---|
| `mok-shim` (recommended) | One blue MokManager screen: set a password, enroll MOK | firmware → `shimx64.efi` → `grubx64.efi` (your signed Limine) → kernels | You just want it to work — pick this |
| `custom-db` (advanced) | Enter firmware Setup Mode and enroll a key into `db` | firmware → Limine directly | You want shim out of the picture entirely |

## What the script does for you

It's idempotent — running it twice is safe.

1. Creates a keypair in `/etc/limine/keys/` (2048-bit, expires in 100
   years) unless one already exists. The keys never leave that directory.
2. Sets `SECURE_BOOT`, `ENABLE_VERIFICATION`, and `ENABLE_ENROLL_CONFIG`
   in `/etc/default/limine`.
3. Re-syncs your kernels with `#<b2sum>` hashes appended to every path,
   bakes the hash of `limine.conf` into Limine's EFI binaries, and signs
   them with `sbsign`.
4. On `mok-shim` only: saves real GRUB as
   `EFI/fedora/grubx64.efi.grub-bak`, puts signed Limine in its place, and
   runs `mokutil --import` to enroll your key.
5. From then on, every kernel update re-signs and re-enrolls automatically.
   If signing tools are missing it warns and keeps going rather than
   breaking your boot update.

## What you still have to do

**mok-shim:**

1. Reboot.
2. On the blue MokManager screen: **Enroll MOK → Continue → Yes**, type the
   password you just set, then **Reboot**.
3. Boot the **Fedora (shim)** entry. (The plain `Limine` entry only works
   with Secure Boot off.)

**custom-db:**

1. Follow the printed Setup Mode instructions.
2. Run `sudo ./fedora-limine-switch.sh --sb-resign`.

## Checking it

```bash
sudo ./fedora-limine-switch.sh --sb-status   # state, keys, signatures, hashes
sudo ./fedora-limine-switch.sh --sb-resign   # re-sign after manual changes
sbverify --cert /etc/limine/keys/MOK.pem /boot/efi/EFI/limine/limine_x64.efi
mokutil --list-enrolled | grep -i limine
```

## Things people get caught by

- `--yes` never enrolls keys — MOK import needs a password and a reboot.
  Run `--sb-setup` interactively when you're ready.
- `dnf update grub2` can put the real `grubx64.efi` back over your signed
  Limine. If Secure Boot then refuses to boot: boot the Fedora entry and run
  `--sb-resign` — it redeploys and re-signs.
- Uninstall offers to restore real GRUB from `.grub-bak`. Enrolled MOKs are
  left behind (harmless); `mokutil --reset` removes them if you care.
- BIOS machines skip all of this — Secure Boot is UEFI-only.

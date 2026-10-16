# NVIDIA + Secure Boot

**Only relevant if you use Secure Boot *and* an NVIDIA driver.** With Secure
Boot off, skip this page entirely.

With Secure Boot on, an unsigned kernel module is a dead module. That means
a black screen and no WiFi, because the kernel's `integrity` lockdown refuses
to load anything not signed by a trusted key.

Tested on an RTX 5070 Ti (Blackwell — open kernel modules are mandatory) with
driver 615.78.08 from NVIDIA's `.run` installer + DKMS across 3+ kernels, plus
a `mt7927` WiFi card. Both were signed with an unenrolled
`CN=DKMS module signing key`.

## The fix: one key for everything

Shim trusts your key for EFI binaries, and the kernel trusts the same key for
modules. So instead of enrolling two keys, the script unifies everything onto
the single Limine MOK:

1. `sb-setup` spots NVIDIA/DKMS and offers to unify them (default: yes).
2. Backs up `/etc/dkms/framework.conf`, then points it at your Limine key:
   ```
   mok_signing_key="/etc/limine/keys/MOK.priv"
   mok_certificate="/etc/limine/keys/MOK.pem"
   ```
3. Runs `dkms autoinstall -k <each kernel>` — only rebuilding kernels whose
   `nvidia.ko` is missing or signed by the old key.
4. Adds an ESP re-sync line to DKMS's `post_transaction` hook (backed up
   first). Without this, DKMS would rebuild the driver *outside*
   `kernel-install`, and Limine would keep serving an initramfs with the old
   module in it.
5. One `mokutil --import` — same reboot as Limine — enrolls the key for EFI
   binaries, kernel modules, and WiFi.

## Using akmod-nvidia from RPM Fusion instead?

Unification doesn't apply (RPM Fusion ships its own signing setup, open
flavor by default, Blackwell included). The script instead offers to enroll
RPM Fusion's `/etc/pki/akmods/certs/public_key.der` in the same MokManager
session.

Don't switch from the `.run` installer to RPM Fusion mid-setup — you'd have
to fully uninstall the `.run` driver first.

## Worth knowing

- GSP firmware blobs don't need signing; firmware isn't checked like modules.
- `nvidia-drm` modeset/fbdev already default to `Y` on driver 615 — no kernel
  cmdline change needed.
- Suspend-to-RAM works under lockdown. Hibernate doesn't (irrelevant with
  zram-only swap anyway).
- No LUKS volumes means no TPM resealing when Secure Boot flips.
- CachyOS kernels ship **unsigned**; Fedora kernels are signed by Fedora.
  Under Secure Boot a CachyOS kernel boots only through Limine (hash-verified
  at boot). The GRUB/shim fallback path demands a kernel signature and will
  refuse it. Fedora kernels work either way.

## When something looks broken

```bash
modinfo -F signer nvidia              # who signed the loaded module?
mokutil --test-key <key.der>          # read the text — exit code is useless
dmesg | grep -iE 'lockdown|key.*reject'
sudo ./fedora-limine-switch.sh --sb-status   # per-kernel signers
```

After a driver update you shouldn't have to do anything — the hook re-syncs
the ESP on its own. If the display goes wrong, run `--sb-status`, then
`--sb-resign`.

# Rocky Linux 9 ISO Validation Plan

This plan validates that the Rocky Linux 9 ISO build boots far enough to run a functioning Linux userspace (kernel + initramfs + systemd/anaconda startup), not just that the ISO artifact exists.

## Acceptance Criteria

- The ISO boots in a VM and reaches a live userspace or installer userspace without kernel panics.
- Automated boot smoke test passes (recommended) and the serial console log contains evidence of:
  - `Linux version ...` (kernel started), and
  - either Anaconda starting (installer ISOs) or systemd reaching a target (live ISOs).

## Automated Validation (Recommended)

### Local (QEMU)

Prereqs:

- `qemu-system-x86_64`
- `xorriso`

Run the boot smoke test:

```bash
bash just_scripts/validate-iso-boot.sh --iso /path/to/rocky9-variant.iso --mode anaconda
```

If label autodetection fails (common for repacked ISOs), pass it explicitly:

```bash
bash just_scripts/validate-iso-boot.sh --iso /path/to/rocky9-variant.iso --mode anaconda --label "Rocky-9-BaseOS-x86_64"
```

For a live ISO (bootc/livecd-style), use:

```bash
bash just_scripts/validate-iso-boot.sh --iso /path/to/rocky9-variant-live.iso --mode live
```

### CI (GitHub Actions)

Use the workflow at `.github/workflows/validate_iso_boot.yml`:

1. Open `Actions -> Validate ISO Boot`.
2. Run the workflow and provide:
   - `iso_url`: a direct download URL to the ISO (release asset URL, artifact URL, etc).
   - `mode`: `anaconda` for installer ISOs, `live` for live ISOs, or `auto` if unsure.
   - `label` (optional): volume label override if autodetection fails.

## Manual Validation (Human Sanity Check)

Boot the ISO in a VM (GNOME Boxes / virt-manager / QEMU) and confirm:

- You reach the expected UI (installer text/GUI for Anaconda, or login/desktop for live).
- A shell is available (either a TTY for live ISOs or an Anaconda console).

From a shell, confirm the OS identity and that the system is running:

```bash
cat /etc/os-release
uname -r
systemctl is-system-running || systemctl --failed
```

Expected: `ID=rocky` and `VERSION_ID="9"` in `/etc/os-release`.


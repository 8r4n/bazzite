# Bazzite CrimsonGold

`bazzite-crimsongold` is a KDE (Kinoite-based) developer build of Bazzite. It is
the standard `bazzite` desktop image plus:

- Developer tooling: `gcc`, `gcc-c++`, `make`, `cmake`, `gdb`, `strace`,
  `ShellCheck`, `git-lfs`, `neovim`, `ripgrep`, `fd-find`, `podman-compose`,
  `python3-pip`, `python3-devel`, `tmux`, `zstd`, `gnupg2`
- VM guest integration for running Bazzite as a virtual machine guest:
  `qemu-guest-agent`, `spice-vdagent`, `spice-webdavd`

The variant is defined in `just_scripts/metadata/variants.json`
(target `bazzite-crimsongold`, features `common gaming crimsongold kde`) and its
package set is gated in the `Containerfile` on the image name / the
`crimsongold` variant feature. CI builds it from the `bazzite-crimsongold`
entry in `.github/workflows/build.yml`.

## Building the container image

Locally (requires rootful podman or docker):

```bash
just build bazzite-crimsongold kinoite
```

This produces `localhost/bazzite-crimsongold-build:43-<branch>`.

In CI, pushing to `main`/`testing` builds and publishes
`ghcr.io/<owner>/bazzite-crimsongold:stable`.

## Building a VM disk image (UTM on macOS)

Bazzite images are bootc-compliant, so a bootable disk image is generated
directly from the container image with
[bootc-image-builder](https://github.com/osbuild/bootc-image-builder):

```bash
just build-vm bazzite-crimsongold kinoite          # qcow2 (default)
just build-vm bazzite-crimsongold kinoite vmdk     # VMware Fusion
just build-vm bazzite-crimsongold kinoite raw      # raw disk
```

Requirements: rootful **podman** (bootc-image-builder reads the image from
`/var/lib/containers/storage`) on an x86_64 Linux host. The image is built
first if it does not exist. Output lands in
`just_scripts/output/vm/<type>/` (e.g. `just_scripts/output/vm/qcow2/disk.qcow2`).

A default login is injected from `just_scripts/vm/config.toml`
(user `crimson`, password `crimsongold`, wheel group) because Anaconda's
user-creation step never runs for a pre-built disk image. Change the password
after first boot, or edit the config before building.

### Importing into UTM

Bazzite's kernel is only published for x86_64, so the guest is an x86_64 VM:

1. Copy `disk.qcow2` to the Mac.
2. UTM → **Create a New Virtual Machine**:
   - **Intel Mac**: choose **Virtualize** → Linux → skip ISO, then attach the
     qcow2 as the primary drive (UTM imports qcow2 natively).
   - **Apple Silicon**: choose **Emulate** → Linux → architecture **x86_64** →
     attach the qcow2. Expect emulation speed (no KVM/HVF for cross-arch).
3. System: 4+ CPU cores, 8 GiB+ RAM recommended; keep the default
   virtio devices (the initramfs is built `--no-hostonly`, so virtio disk and
   network work out of the box). UEFI boot must stay enabled.
4. The SPICE agent tools installed in this variant give the VM clipboard
   sharing and dynamic resolution under UTM's default SPICE display.

### Quick smoke test without a Mac

```bash
qemu-system-x86_64 -machine q35 -m 4G -smp 4 \
  -bios /usr/share/edk2/ovmf/OVMF_CODE.fd \
  -drive file=just_scripts/output/vm/qcow2/disk.qcow2,if=virtio \
  -display none -serial mon:stdio
```

## Installer ISO

The usual ISO paths also work for this variant:

```bash
just build-iso bazzite-crimsongold kinoite
```

or run the `build_iso.yml` workflow with `image_name: bazzite-crimsongold`
(the variant is also part of the default ISO matrix).

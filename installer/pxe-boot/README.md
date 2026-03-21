# PXE boot infrastructure

This directory provides a minimal Docker Compose deployment for PXE-booting a CentOS Stream base installer and handing the install off to an rpm-ostree kickstart.

## Services

- `pxe`: a `dnsmasq`-based PXE/TFTP service built from `quay.io/centos/centos:stream10`
- `ostree-web`: a simple web server, also built from `quay.io/centos/centos:stream10`, that hosts:
  - the generated `kickstarts/centos-ostree.ks`
  - your mirrored or published `ostree/repo` content

## Expected flow

1. A node PXE boots from `dnsmasq`.
2. PXELINUX loads the CentOS Stream kernel and initramfs defined by `CENTOS_INSTALL_ROOT`.
3. Anaconda fetches `kickstarts/centos-ostree.ks` from `ostree-web`.
4. The kickstart installs from the OSTree repository exposed by `OSTREE_REPO_URL`.

## Usage

1. Change into the PXE bundle directory and copy the example environment file:

   ```bash
   cd installer/pxe-boot
   cp .env.example .env
   ```

2. Populate `./httpd/content/ostree/repo` with the CentOS rpm-ostree repository you want clients to install.

3. Start the stack:

   ```bash
   docker compose up --build -d
   ```

4. Point your PXE clients at the host running this compose stack.

The generated kickstart is written to `httpd/content/kickstarts/centos-ostree.ks` when the web service starts.

`CENTOS_INSTALL_ROOT` should be an HTTP-accessible CentOS install tree because the PXE loader fetches the kernel and initramfs directly from that location.

# PXE boot infrastructure

This directory provides a minimal Docker Compose deployment for PXE-booting a CentOS Stream base installer and handing the install off to either a plain OSTree or an ostree-container kickstart.

## Services

- `pxe`: a `dnsmasq`-based PXE/TFTP service built from `quay.io/centos/centos:stream10`
- `ostree-web`: a simple web server, also built from `quay.io/centos/centos:stream10`, that hosts:
  - the generated `kickstarts/centos-ostree.ks`
   - your mirrored or published `ostree/repo` content when using `DEPLOYMENT_TYPE=ostree`

## Expected flow

1. A node PXE boots from `dnsmasq`.
2. PXELINUX loads the CentOS Stream kernel and initramfs defined by `CENTOS_INSTALL_ROOT`.
3. Anaconda fetches `kickstarts/centos-ostree.ks` from `ostree-web`.
4. The kickstart installs from either the OSTree repository exposed by `OSTREE_REPO_URL` or the ostree-container image exposed by `OSTREE_CONTAINER_URL`, depending on `DEPLOYMENT_TYPE`.

## Usage

1. Change into the PXE bundle directory and copy the example environment file:

   ```bash
   cd installer/pxe-boot
   cp .env.example .env
   ```

2. Choose one deployment mode:

   - For `DEPLOYMENT_TYPE=ostree`, populate `./httpd/content/ostree/repo` with the CentOS rpm-ostree repository you want clients to install.
   - For `DEPLOYMENT_TYPE=container`, make sure `OSTREE_CONTAINER_URL` points to a registry image reachable from the installer environment.

3. Start the stack:

   ```bash
   docker compose up --build -d
   ```

4. Point your PXE clients at the host running this compose stack.

The generated kickstart is written to `httpd/content/kickstarts/centos-ostree.ks` when the web service starts.

When `DEPLOYMENT_TYPE=container`, the web service also writes `httpd/content/kickstarts/centos-container.ks`. Point `KICKSTART_PATH` at that file if you want the PXE menu entry to match the install mode by name.

`CENTOS_INSTALL_ROOT` should be an HTTP-accessible CentOS install tree because the PXE loader fetches the kernel and initramfs directly from that location.

## Kickstart modes

### Plain OSTree repository

Use these environment settings when your installer should consume a static OSTree repository over HTTP:

```bash
DEPLOYMENT_TYPE=ostree
OSTREE_REPO_URL=http://192.168.100.2:8080/ostree/repo
OSTREE_REMOTE=centos
OSTREE_OSNAME=centos
OSTREE_REF=centos-stream/10/x86_64/edge
```

Generated kickstart example:

```kickstart
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate
rootpw --lock
firewall --enabled --service=ssh
services --enabled=sshd
zerombr
clearpart --all --initlabel
autopart --type=plain
reboot

ostreesetup --osname=centos --remote=centos --url=http://192.168.100.2:8080/ostree/repo --ref=centos-stream/10/x86_64/edge

%packages
@core
%end
```

### ostree-container image

Use these environment settings when your installer should consume a rechunked OCI archive published to a registry:

```bash
DEPLOYMENT_TYPE=container
KICKSTART_PATH=/kickstarts/centos-container.ks
OSTREE_CONTAINER_URL=ghcr.io/<your-github-owner>/bazzite-custom-gnome-c10s:stable
OSTREE_CONTAINER_TRANSPORT=registry
OSTREE_CONTAINER_NO_SIGNATURE_VERIFICATION=false
```

Generated kickstart example:

```kickstart
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate
rootpw --lock
firewall --enabled --service=ssh
services --enabled=sshd
zerombr
clearpart --all --initlabel
autopart --type=plain
reboot

ostreecontainer --url=ghcr.io/<your-github-owner>/bazzite-custom-gnome-c10s:stable --transport=registry

%packages
@core
%end
```

For static examples outside the PXE bundle, see `installer/kickstarts/centos-stream-10-ostree.ks` for the plain OSTree case and `installer/kickstarts/centos-stream-10.ks` for the ostree-container case.

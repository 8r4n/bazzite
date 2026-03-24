# Airgapped PXE Deployment

This PXE workflow can run fully offline, but only if you collect all external dependencies ahead of time. The two gaps in the default flow are:

- The PXE menu points at a public CentOS install tree.
- The PXE service images are built from online package sources.
- `DEPLOYMENT_TYPE=container` needs a reachable container registry.

The installer-tree gap is now handled by extracting the PXE install tree from a downloaded CentOS ISO instead of mirroring a public web tree.

## Resource Checklist

You need these artifacts before moving into the isolated network:

- A downloaded CentOS ISO that contains the installer tree used for PXE
- The extracted installer tree generated from that ISO for `CENTOS_INSTALL_ROOT`
- Prebuilt `bazzite-pxe-dnsmasq` and `bazzite-ostree-web` images
- A `registry:2` image for the local airgap registry
- Either a mirrored OSTree repository or a container image archive, depending on install mode
- A generated checksum manifest for transfer validation

## Host Requirements

Connected staging host:

- Internet access to download a newer CentOS ISO when you refresh the installer payload, plus any container or OSTree sources you choose to bundle
- `podman` or `docker`
- `skopeo`
- `rsync`
- `xorriso` to extract the installer tree from the ISO
- `ostree` when gathering an OSTree repo from HTTP

Airgapped PXE host:

- `podman` or `docker`
- `skopeo`
- `rsync`
- `sha256sum`
- A local IPv4 address assigned to `PXE_SERVER_IP`
- Ports `67/udp`, `69/udp`, `8080/tcp`, and `5000/tcp` available on the PXE server

## Storage Guidance

Measured from the current repository snapshot:

- Existing OSTree repo under `installer/pxe-boot/httpd/content/ostree/repo`: about `1.6 GiB`
- Existing rechunk output under `just_scripts/output/rechunk`: about `978 MiB`

Additional storage is required for the extracted CentOS install tree, the ISO itself if you keep it in the bundle area, and saved container images. Budget at least `15 GiB` for a single install mode and `20-25 GiB` if you want both OSTree and container modes available in the same transfer bundle.

## Connected-Side Workflow

1. Download the CentOS ISO you want to standardize on for PXE updates.
2. Build or pull the target container image if you plan to test `DEPLOYMENT_TYPE=container`.
3. Run `AIRGAP_INSTALL_ISO=/path/to/CentOS-Stream.iso just gather-airgap`.
4. If your container source is not directly reachable through `OSTREE_CONTAINER_URL`, rerun with `AIRGAP_CONTAINER_SOURCE=<transport:ref>`.
5. Transfer the resulting directory under `just_scripts/output/airgap/` into the isolated environment.

## Airgapped-Side Workflow

1. Copy the bundle into this repository checkout.
2. Run `just stage-airgap`.
3. The script verifies checksums, stages HTTP content, loads the prebuilt PXE images, writes `installer/pxe-boot/.env.airgap`, and starts the PXE stack.
4. For container mode, the script also seeds the local registry on `REGISTRY_PORT`.

## Environment Notes

- The staged airgap env rewrites `CENTOS_INSTALL_ROOT` to `http://<PXE_SERVER_IP>:<HTTP_PORT>/install-root`.
- The staged airgap env rewrites `OSTREE_REPO_URL` to `http://<PXE_SERVER_IP>:<HTTP_PORT>/ostree/repo`.
- The staged airgap env rewrites `OSTREE_CONTAINER_URL` to `PXE_SERVER_IP:REGISTRY_PORT/<name>:<tag>` and enables `OSTREE_CONTAINER_NO_SIGNATURE_VERIFICATION=true`.
- `PXE_SKIP_BUILD=true` is set so the airgapped host uses the prebuilt PXE service images instead of trying to rebuild them.

## Update Model

To refresh the installer payload for a future airgapped cycle:

1. Download the newer CentOS ISO.
2. Re-run `just gather-airgap` with `AIRGAP_INSTALL_ISO` pointing at that ISO.
3. Re-stage the resulting bundle on the isolated PXE host.

This avoids relying on public installer web trees for PXE refreshes.
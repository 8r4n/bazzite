# Airgapped PXE Deployment

This PXE workflow can run fully offline, but only if you collect all external dependencies ahead of time. The two gaps in the default flow are:

- The PXE menu points at a public CentOS install tree.
- The PXE service images are built from online package sources.
- `DEPLOYMENT_TYPE=container` needs a reachable container registry.

## Resource Checklist

You need these artifacts before moving into the isolated network:

- A mirrored CentOS install tree for `CENTOS_INSTALL_ROOT`
- Prebuilt `bazzite-pxe-dnsmasq` and `bazzite-ostree-web` images
- A `registry:2` image for the local airgap registry
- Either a mirrored OSTree repository or a container image archive, depending on install mode
- A generated checksum manifest for transfer validation

## Host Requirements

Connected staging host:

- Internet access to the upstream installer tree, container registry, and OSTree source
- `podman` or `docker`
- `skopeo`
- `rsync`
- `wget` when mirroring the installer tree over HTTP
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

Additional storage is required for the mirrored CentOS install tree and saved container images. Budget at least `15 GiB` for a single install mode and `20-25 GiB` if you want both OSTree and container modes available in the same transfer bundle.

## Connected-Side Workflow

1. Build or pull the target container image if you plan to test `DEPLOYMENT_TYPE=container`.
2. Run `just gather-airgap`.
3. If your container source is not directly reachable through `OSTREE_CONTAINER_URL`, rerun with `AIRGAP_CONTAINER_SOURCE=<transport:ref>`.
4. Transfer the resulting directory under `just_scripts/output/airgap/` into the isolated environment.

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
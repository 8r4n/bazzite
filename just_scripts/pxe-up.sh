#!/usr/bin/bash

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

set -euo pipefail

pxe_root="${project_root}/installer/pxe-boot"
container_mgr=$("${project_root}/just_scripts/container_mgr.sh")

# shellcheck disable=SC1091
. "${project_root}/just_scripts/container_env.sh"

env_file="${pxe_root}/.env"
if [[ ! -f ${env_file} ]]; then
    env_file="${pxe_root}/.env.example"
fi

set -a
# shellcheck disable=SC1090
. "${env_file}"
set +a

cd "${pxe_root}"

if [[ ${container_mgr} == "docker" ]] && docker compose version >/dev/null 2>&1; then
    if [[ ${PXE_SKIP_BUILD,,} == "true" || ${PXE_SKIP_BUILD} == "1" ]]; then
        exec docker compose up -d
    fi

    exec docker compose up --build -d
fi

if [[ ${container_mgr} == "podman" ]] && podman compose version >/dev/null 2>&1; then
    if [[ ${PXE_SKIP_BUILD,,} != "true" && ${PXE_SKIP_BUILD} != "1" ]]; then
        exec podman compose up --build -d
    fi
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "No supported compose provider found and podman is unavailable for fallback." >&2
    exit 1
fi

: "${PXE_SERVER_IP:=}"
: "${HTTP_PORT:=8080}"
: "${REGISTRY_PORT:=5000}"
: "${PXE_DNSMASQ_IMAGE:=localhost/bazzite-pxe-dnsmasq:latest}"
: "${PXE_OSTREE_WEB_IMAGE:=localhost/bazzite-ostree-web:latest}"
: "${PXE_REGISTRY_IMAGE:=docker.io/library/registry:2}"
: "${PXE_SKIP_BUILD:=false}"

if [[ -n ${PXE_SERVER_IP} ]] && ! ip -4 addr show | grep -F "inet ${PXE_SERVER_IP}/" >/dev/null 2>&1; then
    echo "PXE_SERVER_IP ${PXE_SERVER_IP} is not configured on this host." >&2
    echo "Set installer/pxe-boot/.env to a local IPv4 address before starting PXE services." >&2
    exit 1
fi

mkdir -p "${pxe_root}/registry/data"

cleanup_registry_containers() {
    podman rm -f pxe-local-registry bazzite-airgap-registry bazzite-ostree-web bazzite-pxe-dnsmasq >/dev/null 2>&1 || true
    sudo podman rm -f pxe-local-registry bazzite-airgap-registry bazzite-ostree-web bazzite-pxe-dnsmasq >/dev/null 2>&1 || true
}

if [[ ${PXE_SKIP_BUILD,,} != "true" && ${PXE_SKIP_BUILD} != "1" ]]; then
    sudo podman build -t "${PXE_OSTREE_WEB_IMAGE}" ./httpd
    sudo podman build -t "${PXE_DNSMASQ_IMAGE}" ./dnsmasq
fi

cleanup_registry_containers
sudo podman run -d --name bazzite-airgap-registry --restart unless-stopped -p "${REGISTRY_PORT}:5000" -v "${pxe_root}/registry/data:/var/lib/registry:Z" "${PXE_REGISTRY_IMAGE}"
sudo podman run -d --name bazzite-ostree-web --restart unless-stopped --env-file "${env_file}" -p "${HTTP_PORT}:8080" -v "${pxe_root}/httpd/content:/srv/www:Z" "${PXE_OSTREE_WEB_IMAGE}"
sudo podman run -d --name bazzite-pxe-dnsmasq --restart unless-stopped --env-file "${env_file}" --network host --cap-add NET_ADMIN --cap-add NET_RAW -v "${pxe_root}/tftp:/srv/tftp:Z" "${PXE_DNSMASQ_IMAGE}"

sudo podman ps --filter name=bazzite-airgap-registry --filter name=pxe-local-registry --filter name=bazzite-ostree-web --filter name=bazzite-pxe-dnsmasq --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
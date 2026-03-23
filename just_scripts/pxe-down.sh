#!/usr/bin/bash

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

set -euo pipefail

pxe_root="${project_root}/installer/pxe-boot"
container_mgr=$("${project_root}/just_scripts/container_mgr.sh")

# shellcheck disable=SC1091
. "${project_root}/just_scripts/container_env.sh"

cd "${pxe_root}"

if [[ ${container_mgr} == "docker" ]] && docker compose version >/dev/null 2>&1; then
    exec docker compose down
fi

if [[ ${container_mgr} == "podman" ]] && podman compose version >/dev/null 2>&1; then
    exec podman compose down
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "No supported compose provider found and podman is unavailable for fallback." >&2
    exit 1
fi

sudo podman rm -f bazzite-ostree-web bazzite-pxe-dnsmasq >/dev/null 2>&1 || true
sudo podman ps -a --filter name=bazzite-ostree-web --filter name=bazzite-pxe-dnsmasq --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
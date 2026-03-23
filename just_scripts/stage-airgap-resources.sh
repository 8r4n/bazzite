#!/usr/bin/bash

set -euo pipefail

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

usage() {
    cat <<'EOF'
Usage: stage-airgap-resources.sh [options]

Stage a previously gathered airgap bundle onto this PXE host.

Options:
  --bundle-dir <path>     Airgap bundle directory. Default: latest just_scripts/output/airgap/*
  --env-file <path>       Base PXE env file. Default: installer/pxe-boot/.env or .env.example
  --no-activate           Do not replace installer/pxe-boot/.env
  --no-start-stack        Do not start PXE services after staging
  --help                  Show this help

Environment overrides:
  AIRGAP_BUNDLE_DIR
  AIRGAP_ENV_FILE
  AIRGAP_STAGE_ACTIVATE
  AIRGAP_STAGE_START
EOF
}

log() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

is_true() {
    case "${1,,}" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

find_latest_bundle() {
    local root=$1
    local latest

    latest=$(find "${root}" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
    [[ -n ${latest} ]] || die "No airgap bundles found under ${root}"
    printf '%s' "${latest}"
}

load_image_archive() {
    local archive=$1

    case "${container_mgr}" in
        docker)
            docker load -i "${archive}"
            ;;
        podman)
            sudo podman load -i "${archive}"
            ;;
        *)
            die "Unsupported container manager: ${container_mgr}"
            ;;
    esac
}

bundle_dir=${AIRGAP_BUNDLE_DIR:-}
env_file=${AIRGAP_ENV_FILE:-}
activate=${AIRGAP_STAGE_ACTIVATE:-true}
start_stack=${AIRGAP_STAGE_START:-true}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-dir)
            bundle_dir=$2
            shift 2
            ;;
        --env-file)
            env_file=$2
            shift 2
            ;;
        --no-activate)
            activate=false
            shift
            ;;
        --no-start-stack)
            start_stack=false
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

if [[ -z ${bundle_dir} ]]; then
    bundle_dir=$(find_latest_bundle "${project_root}/just_scripts/output/airgap")
fi

[[ -d ${bundle_dir} ]] || die "Bundle directory not found: ${bundle_dir}"

manifest_path="${bundle_dir}/manifest/airgap.env"
checksums_path="${bundle_dir}/manifest/checksums.sha256"

[[ -f ${manifest_path} ]] || die "Missing manifest: ${manifest_path}"
[[ -f ${checksums_path} ]] || die "Missing checksums: ${checksums_path}"

if [[ -z ${env_file} ]]; then
    env_file="${project_root}/installer/pxe-boot/.env"
    if [[ ! -f ${env_file} ]]; then
        env_file="${project_root}/installer/pxe-boot/.env.example"
    fi
fi

[[ -f ${env_file} ]] || die "Env file not found: ${env_file}"

require_cmd sha256sum
require_cmd rsync
require_cmd skopeo

container_mgr=$("${project_root}/just_scripts/container_mgr.sh")
require_cmd "${container_mgr}"

log "Verifying bundle checksums"
(
    cd "${bundle_dir}"
    sha256sum -c manifest/checksums.sha256
)

set -a
# shellcheck disable=SC1090
. "${manifest_path}"
# shellcheck disable=SC1090
. "${env_file}"
set +a

pxe_root="${project_root}/installer/pxe-boot"
mkdir -p "${pxe_root}/httpd/content" "${pxe_root}/registry/data"

log "Syncing HTTP content"
rsync -aH --delete "${bundle_dir}/http-root/" "${pxe_root}/httpd/content/"

log "Loading prebuilt PXE images"
load_image_archive "${bundle_dir}/${AIRGAP_PXE_DNSMASQ_ARCHIVE}"
load_image_archive "${bundle_dir}/${AIRGAP_PXE_OSTREE_WEB_ARCHIVE}"
load_image_archive "${bundle_dir}/${AIRGAP_REGISTRY_ARCHIVE}"

deployment_type=${DEPLOYMENT_TYPE:-ostree}
if [[ -z ${AIRGAP_OSTREE_REPO_RELATIVE} && -n ${AIRGAP_CONTAINER_ARCHIVE_RELATIVE} ]]; then
    deployment_type=container
fi
if [[ -z ${AIRGAP_CONTAINER_ARCHIVE_RELATIVE} && -n ${AIRGAP_OSTREE_REPO_RELATIVE} ]]; then
    deployment_type=ostree
fi

kickstart_path=/kickstarts/centos-ostree.ks
if [[ ${deployment_type} == container ]]; then
    kickstart_path=/kickstarts/centos-container.ks
fi

airgap_env_path="${pxe_root}/.env.airgap"
cat >"${airgap_env_path}" <<EOF
PXE_SERVER_IP=${PXE_SERVER_IP}
DHCP_RANGE=${DHCP_RANGE}
DHCP_ROUTER=${DHCP_ROUTER}
HTTP_PORT=${HTTP_PORT:-8080}
REGISTRY_PORT=${REGISTRY_PORT:-5000}
CENTOS_INSTALL_ROOT=http://${PXE_SERVER_IP}:${HTTP_PORT:-8080}/install-root
KICKSTART_PATH=${kickstart_path}
PXE_SKIP_BUILD=true
PXE_DNSMASQ_IMAGE=${AIRGAP_PXE_DNSMASQ_IMAGE}
PXE_OSTREE_WEB_IMAGE=${AIRGAP_PXE_OSTREE_WEB_IMAGE}
PXE_REGISTRY_IMAGE=${AIRGAP_PXE_REGISTRY_IMAGE}
DEPLOYMENT_TYPE=${deployment_type}
OSTREE_REPO_URL=http://${PXE_SERVER_IP}:${HTTP_PORT:-8080}/ostree/repo
OSTREE_REMOTE=${OSTREE_REMOTE:-centos}
OSTREE_OSNAME=${OSTREE_OSNAME:-centos}
OSTREE_REF=${AIRGAP_OSTREE_REF:-${OSTREE_REF:-centos-stream/10/x86_64/edge}}
OSTREE_CONTAINER_URL=${PXE_SERVER_IP}:${REGISTRY_PORT:-5000}/${AIRGAP_CONTAINER_REPOSITORY}:${AIRGAP_CONTAINER_TAG}
OSTREE_CONTAINER_TRANSPORT=registry
OSTREE_CONTAINER_NO_SIGNATURE_VERIFICATION=true
EOF

if is_true "${activate}"; then
    log "Activating airgap PXE env"
    cp -f "${airgap_env_path}" "${pxe_root}/.env"
fi

if is_true "${start_stack}"; then
    log "Restarting PXE stack"
    (cd "${project_root}" && just pxe-down >/dev/null 2>&1 || true)
    (cd "${project_root}" && just pxe-up)

    if [[ -n ${AIRGAP_CONTAINER_ARCHIVE_RELATIVE} ]]; then
        log "Seeding local registry with container image"
        skopeo copy --dest-tls-verify=false \
            "docker-archive:${bundle_dir}/${AIRGAP_CONTAINER_ARCHIVE_RELATIVE}" \
            "docker://127.0.0.1:${REGISTRY_PORT:-5000}/${AIRGAP_CONTAINER_REPOSITORY}:${AIRGAP_CONTAINER_TAG}"
    fi
fi

log "Airgap resources staged. Active env: ${pxe_root}/.env.airgap"
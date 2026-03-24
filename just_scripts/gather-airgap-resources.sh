#!/usr/bin/bash

set -euo pipefail

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

usage() {
    cat <<'EOF'
Usage: gather-airgap-resources.sh [options]

Gather everything needed to run PXE-based OSTree or ostree-container installs on an airgapped network.

Options:
  --profile <ostree|container|both>   Bundle type to gather. Default: both
  --output-dir <path>                 Bundle destination. Default: just_scripts/output/airgap/<timestamp>
  --env-file <path>                   PXE env file to source. Default: installer/pxe-boot/.env or .env.example
    --install-iso <path>                Path to the CentOS ISO used to seed the installer tree
    --install-source <path>             Override installer tree with a local extracted directory
  --ostree-source <path|url>          Override OSTREE repo source
  --container-source <transport:ref>  Override container image source for skopeo
  --force                             Replace an existing output directory
  --help                              Show this help

Environment overrides:
  AIRGAP_PROFILE
  AIRGAP_OUTPUT_DIR
  AIRGAP_ENV_FILE
    AIRGAP_INSTALL_ISO
  AIRGAP_INSTALL_SOURCE
  AIRGAP_OSTREE_SOURCE
  AIRGAP_CONTAINER_SOURCE
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

shell_quote() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s' "$quoted"
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

extract_iso_tree() {
    local iso_path=$1
    local destination=$2

    require_cmd xorriso
    [[ -f ${iso_path} ]] || die "ISO not found: ${iso_path}"

    rm -rf "${destination}"
    mkdir -p "${destination}"

    xorriso -osirrox on -indev "${iso_path}" -extract / "${destination}" >/dev/null

    [[ -f ${destination}/images/pxeboot/vmlinuz ]] || die "ISO ${iso_path} does not contain images/pxeboot/vmlinuz"
    [[ -f ${destination}/images/pxeboot/initrd.img ]] || die "ISO ${iso_path} does not contain images/pxeboot/initrd.img"
}

save_image_archive() {
    local image_ref=$1
    local archive_path=$2

    case "${container_mgr}" in
        docker)
            docker image inspect "${image_ref}" >/dev/null 2>&1 || docker pull "${image_ref}"
            docker save -o "${archive_path}" "${image_ref}"
            ;;
        podman)
            podman image exists "${image_ref}" >/dev/null 2>&1 || podman pull "${image_ref}"
            podman save -o "${archive_path}" "${image_ref}"
            ;;
        *)
            die "Unsupported container manager: ${container_mgr}"
            ;;
    esac
}

build_pxe_image() {
    local image_ref=$1
    local build_context=$2

    case "${container_mgr}" in
        docker)
            docker build -t "${image_ref}" "${build_context}"
            ;;
        podman)
            podman build -t "${image_ref}" "${build_context}"
            ;;
        *)
            die "Unsupported container manager: ${container_mgr}"
            ;;
    esac
}

sync_local_tree() {
    local source_dir=$1
    local destination=$2

    require_cmd rsync
    rsync -aH --delete "${source_dir%/}/" "${destination}/"
}

sync_install_root() {
    local source=$1
    local destination=$2

    if [[ -d ${source} ]]; then
        log "Copying local installer tree from ${source}"
        sync_local_tree "${source}" "${destination}"
        return
    fi

    if [[ -f ${source} && ${source} == *.iso ]]; then
        log "Extracting installer tree from ISO ${source}"
        extract_iso_tree "${source}" "${destination}"
        return
    fi

    case "${source}" in
        http://*|https://*)
            die "Remote installer trees are no longer supported for airgap gathering. Download a CentOS ISO and pass --install-iso or AIRGAP_INSTALL_ISO instead."
            ;;
        *)
            die "Unsupported install tree source: ${source}"
            ;;
    esac
}

sync_ostree_repo() {
    local source=$1
    local destination=$2

    require_cmd ostree
    rm -rf "${destination}"
    mkdir -p "${destination}"

    if [[ -d ${source} ]]; then
        log "Copying local OSTree repository from ${source}"
        sync_local_tree "${source}" "${destination}"
        ostree --repo="${destination}" summary -u
        return
    fi

    case "${source}" in
        http://*|https://*)
            log "Pulling OSTree ref ${OSTREE_REF} from ${source}"
            ostree --repo="${destination}" init --mode=archive-z2
            ostree --repo="${destination}" remote add --if-not-exists --no-gpg-verify airgap-source "${source}"
            ostree --repo="${destination}" pull --mirror airgap-source "${OSTREE_REF}"
            ostree --repo="${destination}" summary -u
            ;;
        *)
            die "Unsupported OSTree source: ${source}"
            ;;
    esac
}

parse_repo_and_tag() {
    local ref=$1
    local stripped=${ref#*://}
    local repo=${stripped}
    local host=${stripped%%/*}
    local tag=latest

    if [[ ${stripped} == */* ]] && ([[ ${host} == *.* ]] || [[ ${host} == *:* ]] || [[ ${host} == localhost ]]); then
        repo=${stripped#*/}
    fi

    if [[ ${repo} == *:* ]] && [[ ${repo##*:} != */* ]]; then
        tag=${repo##*:}
        repo=${repo%:*}
    fi

    printf '%s\n%s\n' "${repo}" "${tag}"
}

resolve_container_source() {
    local candidate
    local repo_tag
    local repo_name
    local repo_tag_name
    local candidates=()

    if [[ -n ${container_source_override} ]]; then
        candidates+=("${container_source_override}")
    fi

    if [[ -n ${OSTREE_CONTAINER_URL:-} ]]; then
        mapfile -t repo_tag < <(parse_repo_and_tag "${OSTREE_CONTAINER_URL}")
        repo_name=${repo_tag[0]}
        repo_tag_name=${repo_tag[1]}
        candidates+=("containers-storage:localhost/${repo_name}:${repo_tag_name}")
        candidates+=("docker://${OSTREE_CONTAINER_URL}")
    fi

    for candidate in "${candidates[@]}"; do
        if skopeo inspect "${candidate}" >/dev/null 2>&1; then
            printf '%s' "${candidate}"
            return
        fi
    done

    die "Unable to resolve a container source. Set AIRGAP_CONTAINER_SOURCE or pass --container-source."
}

profile=${AIRGAP_PROFILE:-both}
output_dir=${AIRGAP_OUTPUT_DIR:-}
env_file=${AIRGAP_ENV_FILE:-}
install_iso_override=${AIRGAP_INSTALL_ISO:-}
install_source_override=${AIRGAP_INSTALL_SOURCE:-}
ostree_source_override=${AIRGAP_OSTREE_SOURCE:-}
container_source_override=${AIRGAP_CONTAINER_SOURCE:-}
explicit_ostree_repo_url=${OSTREE_REPO_URL-}
explicit_ostree_ref=${OSTREE_REF-}
explicit_ostree_container_url=${OSTREE_CONTAINER_URL-}
has_explicit_ostree_repo_url=${OSTREE_REPO_URL+x}
has_explicit_ostree_ref=${OSTREE_REF+x}
has_explicit_ostree_container_url=${OSTREE_CONTAINER_URL+x}
force=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            profile=$2
            shift 2
            ;;
        --output-dir)
            output_dir=$2
            shift 2
            ;;
        --env-file)
            env_file=$2
            shift 2
            ;;
        --install-iso)
            install_iso_override=$2
            shift 2
            ;;
        --install-source)
            install_source_override=$2
            shift 2
            ;;
        --ostree-source)
            ostree_source_override=$2
            shift 2
            ;;
        --container-source)
            container_source_override=$2
            shift 2
            ;;
        --force)
            force=true
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

case "${profile}" in
    ostree|container|both)
        ;;
    *)
        die "Invalid profile: ${profile}"
        ;;
esac

if [[ -z ${env_file} ]]; then
    env_file="${project_root}/installer/pxe-boot/.env"
    if [[ ! -f ${env_file} ]]; then
        env_file="${project_root}/installer/pxe-boot/.env.example"
    fi
fi

[[ -f ${env_file} ]] || die "Env file not found: ${env_file}"

set -a
# shellcheck disable=SC1090
. "${env_file}"
set +a

if [[ -n ${has_explicit_ostree_repo_url:-} ]]; then
    OSTREE_REPO_URL=${explicit_ostree_repo_url}
fi

if [[ -n ${has_explicit_ostree_ref:-} ]]; then
    OSTREE_REF=${explicit_ostree_ref}
fi

if [[ -n ${has_explicit_ostree_container_url:-} ]]; then
    OSTREE_CONTAINER_URL=${explicit_ostree_container_url}
fi

if [[ -z ${output_dir} ]]; then
    output_dir="${project_root}/just_scripts/output/airgap/$(date -u +%Y%m%dT%H%M%SZ)"
fi

if [[ -e ${output_dir} ]]; then
    if ! is_true "${force}"; then
        die "Output directory already exists: ${output_dir}. Use --force to replace it."
    fi
    rm -rf "${output_dir}"
fi

require_cmd sha256sum
require_cmd skopeo
require_cmd "$(${project_root}/just_scripts/container_mgr.sh)"

container_mgr=$("${project_root}/just_scripts/container_mgr.sh")

install_source=
install_source_kind=

if [[ -n ${install_iso_override} ]]; then
    install_source=${install_iso_override}
    install_source_kind=iso
elif [[ -n ${install_source_override} ]]; then
    install_source=${install_source_override}
    install_source_kind=directory
elif [[ -n ${CENTOS_INSTALL_ROOT:-} && -d ${CENTOS_INSTALL_ROOT} ]]; then
    install_source=${CENTOS_INSTALL_ROOT}
    install_source_kind=directory
fi

[[ -n ${install_source} ]] || die "No local installer source was found. Download a CentOS ISO and pass --install-iso or set AIRGAP_INSTALL_ISO."

if [[ ${install_source_kind} == iso && ! -f ${install_source} ]]; then
    die "Installer ISO not found: ${install_source}"
fi

if [[ ${install_source_kind} == directory && ! -d ${install_source} ]]; then
    die "Installer tree directory not found: ${install_source}"
fi

ostree_source=${ostree_source_override:-}

if [[ -z ${ostree_source} && -d ${project_root}/installer/pxe-boot/httpd/content/ostree/repo ]]; then
    ostree_source=${project_root}/installer/pxe-boot/httpd/content/ostree/repo
fi
if [[ -z ${ostree_source} ]]; then
    ostree_source=${OSTREE_REPO_URL:-}
fi

bundle_http_root="${output_dir}/http-root"
bundle_images="${output_dir}/images"
bundle_manifest_dir="${output_dir}/manifest"
bundle_container_dir="${output_dir}/container"

mkdir -p "${bundle_http_root}/install-root" "${bundle_http_root}/ostree" "${bundle_images}" "${bundle_manifest_dir}" "${bundle_container_dir}"

log "Building PXE service images"
pxe_web_image="localhost/bazzite-ostree-web:airgap"
pxe_dnsmasq_image="localhost/bazzite-pxe-dnsmasq:airgap"
registry_image="docker.io/library/registry:2"
build_pxe_image "${pxe_web_image}" "${project_root}/installer/pxe-boot/httpd"
build_pxe_image "${pxe_dnsmasq_image}" "${project_root}/installer/pxe-boot/dnsmasq"

log "Saving PXE service images"
pxe_web_archive="images/bazzite-ostree-web-airgap.tar"
pxe_dnsmasq_archive="images/bazzite-pxe-dnsmasq-airgap.tar"
registry_archive="images/registry-2.tar"
save_image_archive "${pxe_web_image}" "${output_dir}/${pxe_web_archive}"
save_image_archive "${pxe_dnsmasq_image}" "${output_dir}/${pxe_dnsmasq_archive}"
save_image_archive "${registry_image}" "${output_dir}/${registry_archive}"

log "Gathering installer tree"
sync_install_root "${install_source}" "${bundle_http_root}/install-root"

ostree_repo_relative=
container_archive_relative=
container_repository=
container_tag=

if [[ ${profile} == ostree || ${profile} == both ]]; then
    [[ -n ${ostree_source} ]] || die "No OSTree source was found. Set AIRGAP_OSTREE_SOURCE or pass --ostree-source."
    log "Gathering OSTree repository"
    sync_ostree_repo "${ostree_source}" "${bundle_http_root}/ostree/repo"
    ostree_repo_relative="http-root/ostree/repo"
fi

if [[ ${profile} == container || ${profile} == both ]]; then
    log "Gathering ostree-container image"
    container_source=$(resolve_container_source)
    mapfile -t container_ref_parts < <(parse_repo_and_tag "${OSTREE_CONTAINER_URL}")
    container_repository=${container_ref_parts[0]}
    container_tag=${container_ref_parts[1]}
    container_archive_relative="container/${container_repository//\//-}-${container_tag}.docker-archive.tar"
    skopeo copy "${container_source}" "docker-archive:${output_dir}/${container_archive_relative}:${container_repository}:${container_tag}"
fi

cp -f "${env_file}" "${bundle_manifest_dir}/source.env"

manifest_path="${bundle_manifest_dir}/airgap.env"
{
    printf 'AIRGAP_PROFILE=%s\n' "$(shell_quote "${profile}")"
    printf 'AIRGAP_CREATED_AT=%s\n' "$(shell_quote "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf 'AIRGAP_INSTALL_SOURCE=%s\n' "$(shell_quote "${install_source}")"
    printf 'AIRGAP_INSTALL_SOURCE_KIND=%s\n' "$(shell_quote "${install_source_kind}")"
    printf 'AIRGAP_INSTALL_ROOT_RELATIVE=%s\n' "$(shell_quote "http-root/install-root")"
    printf 'AIRGAP_PXE_DNSMASQ_IMAGE=%s\n' "$(shell_quote "${pxe_dnsmasq_image}")"
    printf 'AIRGAP_PXE_OSTREE_WEB_IMAGE=%s\n' "$(shell_quote "${pxe_web_image}")"
    printf 'AIRGAP_PXE_REGISTRY_IMAGE=%s\n' "$(shell_quote "${registry_image}")"
    printf 'AIRGAP_PXE_DNSMASQ_ARCHIVE=%s\n' "$(shell_quote "${pxe_dnsmasq_archive}")"
    printf 'AIRGAP_PXE_OSTREE_WEB_ARCHIVE=%s\n' "$(shell_quote "${pxe_web_archive}")"
    printf 'AIRGAP_REGISTRY_ARCHIVE=%s\n' "$(shell_quote "${registry_archive}")"
    printf 'AIRGAP_OSTREE_REPO_RELATIVE=%s\n' "$(shell_quote "${ostree_repo_relative}")"
    printf 'AIRGAP_CONTAINER_ARCHIVE_RELATIVE=%s\n' "$(shell_quote "${container_archive_relative}")"
    printf 'AIRGAP_CONTAINER_REPOSITORY=%s\n' "$(shell_quote "${container_repository}")"
    printf 'AIRGAP_CONTAINER_TAG=%s\n' "$(shell_quote "${container_tag}")"
    printf 'AIRGAP_OSTREE_REF=%s\n' "$(shell_quote "${OSTREE_REF:-}")"
} >"${manifest_path}"

(
    cd "${output_dir}"
    find . -type f ! -path './manifest/checksums.sha256' -print0 | sort -z | xargs -0 sha256sum > manifest/checksums.sha256
)

log "Airgap bundle created at ${output_dir}"
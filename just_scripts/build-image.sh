#!/usr/bin/bash
set -eo pipefail
if [[ -z ${project_root} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi
if [[ -z ${git_branch} ]]; then
    git_branch=$(git branch --show-current)
fi

git_branch_tag=${git_branch//\//-}
git_branch_tag=${git_branch_tag//[^a-zA-Z0-9_.-]/-}

# Get Inputs
target=$1
image=$2
requested_target=$target
requested_image=$image

# Set image/target/version based on inputs
# shellcheck disable=SC2154,SC1091
. "${project_root}/just_scripts/get-defaults.sh"

require_command() {
    local cmd=$1
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Missing required command: ${cmd}" >&2
        exit 1
    fi
}

hash_install_root() {
    local install_root=$1

    find "${install_root}" -type f \( -path '*/repodata/repomd.xml' -o -name '.treeinfo' \) -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sha256sum \
        | awk '{print $1}'
}

validate_install_root() {
    local install_root=$1
    local install_label=$2

    for repo_name in BaseOS AppStream; do
        if [[ ! -d "${install_root}/${repo_name}/repodata" ]]; then
            echo "${install_label} install root is missing ${repo_name}/repodata: ${install_root}" >&2
            exit 1
        fi
    done
}

# Get info
container_mgr=$(just _container_mgr)
# shellcheck disable=SC1091
. "${project_root}/just_scripts/container_env.sh"
tag=$(just _tag "${image}")
container_target=${target}

centos_install_root_rel=""
centos_install_source_kind=""
centos_install_source_id=""
centos_install_source_sha256=""
rhel_install_root_rel=""
rhel_install_source_kind=""
rhel_install_source_id=""
rhel_install_source_sha256=""

if [[ ${target} == "bazzite-custom" ]]; then
    container_target="bazzite"
fi

if [[ ${target} =~ "nvidia" ]]; then
    flavor="nvidia"
else
    flavor="main"
fi

if [[ ${base_image_name} == "centos-stream-10" ]]; then
    if [[ -z ${BAZZITE_CENTOS_BASE_IMAGE:-} ]]; then
        BAZZITE_CENTOS_BASE_IMAGE=$("${project_root}/just_scripts/build-centos-base-image.sh" "${requested_target}" "${requested_image}")
    fi

    if [[ -n ${BAZZITE_CENTOS_INSTALL_ISO:-} && -n ${BAZZITE_CENTOS_INSTALL_ROOT:-} ]]; then
        echo "Set either BAZZITE_CENTOS_INSTALL_ISO or BAZZITE_CENTOS_INSTALL_ROOT, not both." >&2
        exit 1
    fi

    if [[ -z ${BAZZITE_CENTOS_INSTALL_ISO:-} && -z ${BAZZITE_CENTOS_INSTALL_ROOT:-} ]]; then
        echo "CentOS Stream 10 builds now require BAZZITE_CENTOS_INSTALL_ISO or BAZZITE_CENTOS_INSTALL_ROOT." >&2
        exit 1
    fi

    centos_install_root_rel="just_scripts/output/centos-install-root"
    centos_install_root_abs="${project_root}/${centos_install_root_rel}"
    rm -rf "${centos_install_root_abs}"
    mkdir -p "${centos_install_root_abs}"

    if [[ -n ${BAZZITE_CENTOS_INSTALL_ISO:-} ]]; then
        require_command xorriso
        require_command sha256sum

        centos_install_iso=$(readlink -f "${BAZZITE_CENTOS_INSTALL_ISO}")
        if [[ ! -f ${centos_install_iso} ]]; then
            echo "CentOS install ISO not found: ${BAZZITE_CENTOS_INSTALL_ISO}" >&2
            exit 1
        fi

        xorriso -osirrox on -indev "${centos_install_iso}" -extract / "${centos_install_root_abs}" >/dev/null
        validate_install_root "${centos_install_root_abs}" "CentOS"

        centos_install_source_kind="iso"
        centos_install_source_id=$(basename "${centos_install_iso}")
        centos_install_source_sha256=$(sha256sum "${centos_install_iso}" | awk '{print $1}')
    else
        require_command rsync
        require_command sha256sum

        source_install_root=$(readlink -f "${BAZZITE_CENTOS_INSTALL_ROOT}")
        if [[ ! -d ${source_install_root} ]]; then
            echo "CentOS install root not found: ${BAZZITE_CENTOS_INSTALL_ROOT}" >&2
            exit 1
        fi

        rsync -a --delete "${source_install_root}/" "${centos_install_root_abs}/"
        validate_install_root "${centos_install_root_abs}" "CentOS"

        centos_install_source_kind="tree"
        centos_install_source_id=$(basename "${source_install_root}")
        centos_install_source_sha256=$(hash_install_root "${centos_install_root_abs}")
    fi
fi

if [[ ${base_image_name} == "rhel-10" ]]; then
    if [[ -z ${BAZZITE_RHEL_BASE_IMAGE:-} ]]; then
        BAZZITE_RHEL_BASE_IMAGE=$("${project_root}/just_scripts/build-rhel-base-image.sh" "${requested_target}" "${requested_image}")
    fi

    if [[ -n ${BAZZITE_RHEL_INSTALL_ISO:-} && -n ${BAZZITE_RHEL_INSTALL_ROOT:-} ]]; then
        echo "Set either BAZZITE_RHEL_INSTALL_ISO or BAZZITE_RHEL_INSTALL_ROOT, not both." >&2
        exit 1
    fi

    if [[ -z ${BAZZITE_RHEL_INSTALL_ISO:-} && -z ${BAZZITE_RHEL_INSTALL_ROOT:-} ]]; then
        echo "RHEL 10 builds now require BAZZITE_RHEL_INSTALL_ISO or BAZZITE_RHEL_INSTALL_ROOT." >&2
        exit 1
    fi

    rhel_install_root_rel="just_scripts/output/rhel-install-root"
    rhel_install_root_abs="${project_root}/${rhel_install_root_rel}"
    rm -rf "${rhel_install_root_abs}"
    mkdir -p "${rhel_install_root_abs}"

    if [[ -n ${BAZZITE_RHEL_INSTALL_ISO:-} ]]; then
        require_command xorriso
        require_command sha256sum

        rhel_install_iso=$(readlink -f "${BAZZITE_RHEL_INSTALL_ISO}")
        if [[ ! -f ${rhel_install_iso} ]]; then
            echo "RHEL install ISO not found: ${BAZZITE_RHEL_INSTALL_ISO}" >&2
            exit 1
        fi

        xorriso -osirrox on -indev "${rhel_install_iso}" -extract / "${rhel_install_root_abs}" >/dev/null
        validate_install_root "${rhel_install_root_abs}" "RHEL"

        rhel_install_source_kind="iso"
        rhel_install_source_id=$(basename "${rhel_install_iso}")
        rhel_install_source_sha256=$(sha256sum "${rhel_install_iso}" | awk '{print $1}')
    else
        require_command rsync
        require_command sha256sum

        source_install_root=$(readlink -f "${BAZZITE_RHEL_INSTALL_ROOT}")
        if [[ ! -d ${source_install_root} ]]; then
            echo "RHEL install root not found: ${BAZZITE_RHEL_INSTALL_ROOT}" >&2
            exit 1
        fi

        rsync -a --delete "${source_install_root}/" "${rhel_install_root_abs}/"
        validate_install_root "${rhel_install_root_abs}" "RHEL"

        rhel_install_source_kind="tree"
        rhel_install_source_id=$(basename "${source_install_root}")
        rhel_install_source_sha256=$(hash_install_root "${rhel_install_root_abs}")
    fi
fi

build_args=(
    -f Containerfile
    --build-arg="IMAGE_NAME=${tag}"
    --build-arg="IMAGE_VENDOR=ublue-os"
    --build-arg="IMAGE_BRANCH=${git_branch_tag}"
    --build-arg="BASE_IMAGE_NAME=${base_image_name}"
    --build-arg="BASE_IMAGE_FAMILY=${base_image_family}"
    --build-arg="BASE_VARIANT_NAME=${base_variant_name}"
    --build-arg="BASE_VERSION=${build_version}"
    --build-arg="SHA_HEAD_SHORT=$(git -C "${project_root}" rev-parse --short HEAD)"
    --build-arg="VERSION_TAG=${build_version}"
    --build-arg="VERSION_PRETTY=${build_version}"
    --build-arg="KERNEL_FLAVOR=bazzite"
    --build-arg="SOURCE_IMAGE=${source_image%-main}-${flavor}"
    --build-arg="FEDORA_VERSION=${content_version}"
    --build-arg="CENTOS_INSTALL_ROOT=${centos_install_root_rel}"
    --build-arg="CENTOS_INSTALL_SOURCE_KIND=${centos_install_source_kind}"
    --build-arg="CENTOS_INSTALL_SOURCE_ID=${centos_install_source_id}"
    --build-arg="CENTOS_INSTALL_SOURCE_SHA256=${centos_install_source_sha256}"
    --build-arg="RHEL_INSTALL_ROOT=${rhel_install_root_rel}"
    --build-arg="RHEL_INSTALL_SOURCE_KIND=${rhel_install_source_kind}"
    --build-arg="RHEL_INSTALL_SOURCE_ID=${rhel_install_source_id}"
    --build-arg="RHEL_INSTALL_SOURCE_SHA256=${rhel_install_source_sha256}"
    --target="${container_target}"
    --tag localhost/"${tag}:${build_version}-${git_branch_tag}"
)

if [[ -n ${BAZZITE_CENTOS_BASE_IMAGE:-} && ${base_image_name} == "centos-stream-10" ]]; then
    build_args+=(--build-arg="BASE_IMAGE=${BAZZITE_CENTOS_BASE_IMAGE}")
fi

if [[ -n ${BAZZITE_RHEL_BASE_IMAGE:-} && ${base_image_name} == "rhel-10" ]]; then
    build_args+=(--build-arg="BASE_IMAGE=${BAZZITE_RHEL_BASE_IMAGE}")
fi

if [[ ${container_mgr} == "docker" ]]; then
    docker_builder="${BAZZITE_DOCKER_BUILDER:-bazzite-builder}"

    if ! docker buildx inspect "${docker_builder}" >/dev/null 2>&1; then
        docker buildx create --name "${docker_builder}" --driver docker-container --bootstrap >/dev/null
    fi

    docker buildx build --builder "${docker_builder}" --load \
        "${build_args[@]}" \
        "${project_root}"
else
    $container_mgr build \
        "${build_args[@]}" \
        "${project_root}"
fi

if [[ ${base_image_name} == "rhel-10" ]]; then
    "${project_root}/just_scripts/sanitize-rhel-offline-image.sh" "localhost/${tag}:${build_version}-${git_branch_tag}" "${container_mgr}"
    "${project_root}/just_scripts/check-rhel-offline-image.sh" "localhost/${tag}:${build_version}-${git_branch_tag}" "${container_mgr}"
fi

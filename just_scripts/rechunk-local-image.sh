#!/usr/bin/bash
set -euo pipefail

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi

if [[ -z ${git_branch:-} ]]; then
    git_branch=$(git -C "${project_root}" branch --show-current)
fi

target=${1:-bazzite-custom}
image=${2:-centos}

# Set image/target/version defaults using the same logic as the build path.
# shellcheck disable=SC1091
. "${project_root}/just_scripts/get-defaults.sh"

if [[ ${base_image_name} != "centos-stream-10" ]]; then
    echo "Local rechunking is currently supported only for the CentOS Stream 10 image path." >&2
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "podman is required for local rechunking." >&2
    exit 1
fi

if ! command -v skopeo >/dev/null 2>&1; then
    echo "skopeo is required for local rechunking." >&2
    exit 1
fi

tag=$(just _tag "${image}")
ref=${BAZZITE_RECHUNK_REF:-localhost/${tag}:${build_version}-${git_branch}}
prev_ref=${BAZZITE_RECHUNK_PREV_REF:-}
version=${BAZZITE_RECHUNK_VERSION:-${build_version}-${git_branch}}
pretty=${BAZZITE_RECHUNK_PRETTY:-Local ${base_variant_name} (${git_branch})}
description=${BAZZITE_RECHUNK_DESCRIPTION:-Bazzite ${base_variant_name} local rechunk build.}
revision=${BAZZITE_RECHUNK_REVISION:-$(git -C "${project_root}" rev-parse HEAD)}
created=${BAZZITE_RECHUNK_CREATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
rechunk_image=${BAZZITE_RECHUNKER_IMAGE:-ghcr.io/ublue-os/legacy-rechunk:v1.0.0-x86_64}
max_layers=${BAZZITE_RECHUNK_MAX_LAYERS:-}
skip_compression=${BAZZITE_RECHUNK_SKIP_COMPRESSION:-}
clear_plan=${BAZZITE_RECHUNK_CLEAR_PLAN:-}
meta_file=${BAZZITE_RECHUNK_META:-}
output_dir=${BAZZITE_RECHUNK_OUTPUT_DIR:-${project_root}/just_scripts/output/rechunk}
keep_cache=${BAZZITE_RECHUNK_KEEP_CACHE:-}

out_name=$(echo "${ref}" | rev | cut -d'/' -f1 | rev | sed 's/:/_/')
workspace_dir="${output_dir}"
location="${workspace_dir}/${out_name}"
version_file="${workspace_dir}/version.txt"

if [[ -e ${location} && -z ${BAZZITE_RECHUNK_OVERWRITE:-} ]]; then
    echo "Output already exists at ${location}. Set BAZZITE_RECHUNK_OVERWRITE=1 to replace it." >&2
    exit 1
fi

mkdir -p "${workspace_dir}"
if [[ -e ${location} ]]; then
    chmod 755 "${location}" 2>/dev/null || true
    chmod -R u+rwX "${location}" 2>/dev/null || true
fi
rm -rf "${location}" "${version_file}"

labels=$(cat <<EOF
io.artifacthub.package.logo-url=https://raw.githubusercontent.com/ublue-os/bazzite/main/repo_content/logo.png
io.artifacthub.package.readme-url=https://raw.githubusercontent.com/ublue-os/bazzite/refs/heads/main/README.md
org.opencontainers.image.created=${created}
org.opencontainers.image.description=${description}
org.opencontainers.image.licenses=Apache-2.0
org.opencontainers.image.revision=${revision}
org.opencontainers.image.source=https://bazzite.gg
org.opencontainers.image.title=Bazzite
org.opencontainers.image.vendor=Universal Blue
org.opencontainers.image.url=https://bazzite.gg
EOF
)

cache_volume="cache_ostree"
container_ref=""
source_ref="${ref}"
mount_path=""

cleanup() {
    local exit_code=$?

    if [[ -n ${container_ref} ]]; then
        podman unshare podman unmount "${container_ref}" >/dev/null 2>&1 || true
        podman rm "${container_ref}" >/dev/null 2>&1 || true
    fi

    if [[ -z ${keep_cache} ]]; then
        podman volume rm "${cache_volume}" >/dev/null 2>&1 || true
    fi

    exit ${exit_code}
}

trap cleanup EXIT

echo "Pulling rechunker image ${rechunk_image}"
podman pull "${rechunk_image}" >/dev/null

echo "Mounting ${source_ref}"
container_ref=$(podman create "${source_ref}" bash)
mount_path=$(podman unshare podman mount "${container_ref}")

echo "Pruning mounted tree"
podman run --rm \
    -v "${mount_path}:/var/tree" \
    -e TREE=/var/tree \
    -u 0:0 \
    "${rechunk_image}" \
    /sources/rechunk/1_prune.sh

echo "Creating fresh OSTree commit"
podman run --rm \
    -v "${mount_path}:/var/tree" \
    -e TREE=/var/tree \
    -v "${cache_volume}:/var/ostree" \
    -e REPO=/var/ostree/repo \
    -e RESET_TIMESTAMP=1 \
    -u 0:0 \
    "${rechunk_image}" \
    /sources/rechunk/2_create.sh

echo "Unmounting source image"
podman unshare podman unmount "${container_ref}"
podman rm "${container_ref}"
container_ref=""
mount_path=""

if [[ -n ${meta_file} ]]; then
    cp "${meta_file}" "${workspace_dir}/_meta_in.yml"
fi

chunk_args=(
    --rm
    -v "${workspace_dir}:/workspace"
    -v "${project_root}:/var/git"
    -v "${cache_volume}:/var/ostree"
    -e "REPO=/var/ostree/repo"
    -e "PREV_REF=${prev_ref}"
    -e "OUT_NAME=${out_name}"
    -e "LABELS=${labels}"
    -e "VERSION=${version}"
    -e "VERSION_FN=/workspace/version.txt"
    -e "PRETTY=${pretty}"
    -e "DESCRIPTION=${description}"
    -e "CHANGELOG="
    -e "OUT_REF=oci:${out_name}"
    -e "GIT_DIR=/var/git"
    -e "CLEAR_PLAN=${clear_plan}"
    -e "REVISION=${revision}"
    -u 0:0
)

if [[ -n ${max_layers} ]]; then
    chunk_args+=( -e "MAX_LAYERS=${max_layers}" )
fi

if [[ -n ${skip_compression} ]]; then
    chunk_args+=( -e "SKIP_COMPRESSION=${skip_compression}" )
fi

echo "Rechunking into ${location}"
podman run "${chunk_args[@]}" "${rechunk_image}" /sources/rechunk/3_chunk.sh

# Rootless rechunk can leave OCI directories without traverse bits, which breaks
# local inspection even when the current user owns the files.
chmod 755 "${location}"
chmod -R u+rwX,go+rX "${location}"
chmod 644 "${version_file}"

echo "Validating OCI output"
skopeo inspect "oci:${location}" >/dev/null

echo
echo "Rechunked image created successfully"
echo "  Source ref: ${ref}"
echo "  OCI path:   ${location}"
echo "  OCI ref:    oci:${location}"
echo "  Version:    $(cat "${version_file}")"
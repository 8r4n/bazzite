#!/usr/bin/bash
#shellcheck disable=SC2154

if [[ -z ${project_root} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi
if [[ -z ${git_branch} ]]; then
    git_branch=$(git branch --show-current)
fi

# shellcheck disable=SC1091
. "${project_root}/just_scripts/sudoif.sh"

# Check if inside rootless container
if [[ -f /run/.containerenv ]]; then
    #shellcheck disable=SC1091
    source /run/.containerenv
    #shellcheck disable=SC2154
    if [[ "${rootless}" -eq "1" ]]; then
        echo "Cannot build VM images inside rootless podman container... Exiting..."
        exit 1
    fi
fi
container_mgr=$(just _container_mgr)
# shellcheck disable=SC1091
. "${project_root}/just_scripts/container_env.sh"
# bootc-image-builder reads the image from rootful containers-storage
if [[ ${container_mgr} != *podman* ]]; then
    echo "VM image builds require podman (bootc-image-builder mounts /var/lib/containers/storage)... Exiting..."
    exit 1
fi
if "${container_mgr}" info | grep Root | grep -q /home; then
    echo "Cannot build VM images with rootless container..."
    exit 1
fi

# Get Inputs
target=$1
image=$2
orig_image=$2
image_type=${3:-qcow2}

case ${image_type} in
    qcow2 | raw | vmdk | vhd)
        ;;
    *)
        echo "Unsupported VM image type: ${image_type} (expected qcow2, raw, vmdk, or vhd)" >&2
        exit 1
        ;;
esac

# Set image/target/version based on inputs
# shellcheck disable=SC2154,SC1091
. "${project_root}/just_scripts/get-defaults.sh"

# Set Container tag name
tag=$(just _tag "${image}")
builder_image=quay.io/centos-bootc/bootc-image-builder:latest
vm_config="${project_root}/just_scripts/vm/config.toml"
output_dir="${project_root}/just_scripts/output/vm"

# Make sure image actually exists, build if it doesn't
ID=$(${container_mgr} images --filter reference=localhost/"${tag}:${build_version}-${git_branch}" --format "{{.ID}}")
if [[ -z ${ID} ]]; then
    just build "${target}" "${orig_image}"
fi

sudoif mkdir -p "${output_dir}"

sudoif "${container_mgr}" run \
    --rm \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    --volume "${vm_config}":/config.toml:ro \
    --volume "${output_dir}":/output \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    "${builder_image}" \
    --type "${image_type}" \
    --rootfs btrfs \
    "localhost/${tag}:${build_version}-${git_branch}"

echo "VM image written under ${output_dir}/${image_type}/"

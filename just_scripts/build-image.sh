#!/usr/bin/bash
set -eo pipefail
if [[ -z ${project_root} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi
if [[ -z ${git_branch} ]]; then
    git_branch=$(git branch --show-current)
fi

# Get Inputs
target=$1
image=$2

# Set image/target/version based on inputs
# shellcheck disable=SC2154,SC1091
. "${project_root}/just_scripts/get-defaults.sh"

# Get info
container_mgr=$(just _container_mgr)
# shellcheck disable=SC1091
. "${project_root}/just_scripts/container_env.sh"
tag=$(just _tag "${image}")
container_target=${target}

if [[ ${target} == "bazzite-custom" ]]; then
    container_target="bazzite"
fi

if [[ ${target} =~ "nvidia" ]]; then
    flavor="nvidia"
else
    flavor="main"
fi

build_args=(
    -f Containerfile
    --build-arg="IMAGE_NAME=${tag}"
    --build-arg="IMAGE_VENDOR=ublue-os"
    --build-arg="IMAGE_BRANCH=${git_branch}"
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
    --target="${container_target}"
    --tag localhost/"${tag}:${build_version}-${git_branch}"
)

if [[ -n ${BAZZITE_CENTOS_BASE_IMAGE:-} && ${base_image_name} == "centos-stream-10" ]]; then
    build_args+=(--build-arg="BASE_IMAGE=${BAZZITE_CENTOS_BASE_IMAGE}")
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

#!/usr/bin/bash
if [[ -z "${image}" ]]; then
    image=${default_image}
fi

if [[ -z "${target}" ]]; then
    target=${default_target}
elif [[ ${target} == "deck" ]]; then
    target="bazzite-deck"
elif [[ ${target} == "nvidia" ]]; then
    target="bazzite-nvidia"
fi

valid_images=(
    silverblue
    kinoite
    gnome
    kde
    centos
    centos-stream-10
    c10s
)
image=${image,,}
if [[ ! ${valid_images[*]} =~ ${image} ]]; then
    echo "Invalid image..."
    exit 1
fi

target=${target,,}
valid_targets=(
    bazzite
    bazzite-custom
    bazzite-deck
    bazzite-nvidia
)
if [[ ! ${valid_targets[*]} =~ ${target} ]]; then
    echo "Invalid target..."
    exit 1
fi

desktop=""
build_version=${latest}
content_version=${latest}
base_image_name="kinoite"
base_image_family="kinoite"
base_variant_name="Kinoite"
source_image="kinoite-main"
flatpak_dir_shortname="installer/kde_flatpaks"
flatpak_bootstrap_image="kinoite"
flatpak_bootstrap_version=${latest}
image_variant_suffix=""

case "${image}" in
    gnome|silverblue)
        base_image_name="silverblue"
        base_image_family="silverblue"
        base_variant_name="Silverblue"
        source_image="silverblue-main"
        flatpak_dir_shortname="installer/gnome_flatpaks"
        flatpak_bootstrap_image="silverblue"
        desktop="-gnome"
        ;;
    centos|centos-stream-10|c10s)
        base_image_name="centos-stream-10"
        base_image_family="silverblue"
        base_variant_name="CentOS Stream 10"
        source_image="${BAZZITE_CENTOS_SOURCE_IMAGE:-centos-stream-10-main}"
        build_version="${BAZZITE_CENTOS_VERSION:-10}"
        content_version="${BAZZITE_CENTOS_FEDORA_VERSION:-${latest}}"
        flatpak_dir_shortname="installer/gnome_flatpaks"
        flatpak_bootstrap_image="silverblue"
        flatpak_bootstrap_version=${latest}
        desktop="-gnome"
        image_variant_suffix="-c10s"
        ;;
esac

if [[ ${base_image_name} == "centos-stream-10" && ${target} != "bazzite" && ${target} != "bazzite-custom" ]]; then
    echo "CentOS Stream 10 builds only support desktop targets."
    exit 1
fi

if [[ ${image} == "gnome" || ${image} == "silverblue" || ${image} == "centos" || ${image} == "centos-stream-10" || ${image} == "c10s" ]]; then
    desktop="-gnome"
fi
image="${target}${desktop}"
if [[ ${image} =~ "nvidia" ]]; then
    image="bazzite${desktop}-nvidia"
fi
image="${image}${image_variant_suffix}"


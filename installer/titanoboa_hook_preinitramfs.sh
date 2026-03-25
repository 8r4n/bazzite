#!/usr/bin/env bash
#
set -exo pipefail

dnf_repo_args=()
if [[ ${BAZZITE_OFFLINE_INSTALL_MODE:-false} == true && -n ${BAZZITE_OFFLINE_DNF_REPO_IDS:-} ]]; then
    dnf_repo_args=(--disablerepo='*')
    IFS=',' read -r -a repo_ids <<<"${BAZZITE_OFFLINE_DNF_REPO_IDS}"
    for repo_id in "${repo_ids[@]}"; do
        dnf_repo_args+=(--enablerepo="${repo_id}")
    done
fi

dnf_install() {
    dnf "${dnf_repo_args[@]}" -y "$@"
}

# Swap kernel with vanilla and rebuild initramfs.
#
# This is done because we want the initramfs to use a signed
# kernel for secureboot.
kernel_pkgs=(
    kernel
    kernel-core
    kernel-devel
    kernel-devel-matched
    kernel-modules
    kernel-modules-core
    kernel-modules-extra
)
dnf -y versionlock delete "${kernel_pkgs[@]}"
dnf --setopt=protect_running_kernel=False -y remove "${kernel_pkgs[@]}"
(cd /usr/lib/modules && rm -rf -- ./*)
dnf_install --setopt=tsflags=noscripts install kernel kernel-core
kernel=$(find /usr/lib/modules -maxdepth 1 -type d -printf '%P\n' | grep .)
depmod "$kernel"

imageref="$(podman images --format '{{ index .Names 0 }}\n' 'bazzite*' | head -1)"
imageref="${imageref##*://}"
imageref="${imageref%%:*}"

# Include nvidia-gpu-firmware package.
dnf_install -q install nvidia-gpu-firmware || :
dnf clean all -yq

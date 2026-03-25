#!/usr/bin/bash
# Ref: https://github.com/ondrejbudai/bootc-isos/blob/3b3a185e4a57947f57baf53d2be5aee469274f98/bazzite/src/build.sh

set -exo pipefail

{ export PS4='+( ${BASH_SOURCE}:${LINENO} ): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; } 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE=${BASE_IMAGE:?}
INSTALL_IMAGE_PAYLOAD=${INSTALL_IMAGE_PAYLOAD:?}
FLATPAK_DIR_SHORTNAME=${FLATPAK_DIR_SHORTNAME:?}

offline_install_root=
offline_skip_flatpaks=false
dnf_repo_args=()

configure_offline_repos() {
    local install_root=$1

    mkdir -p /etc/dnf/plugins /etc/yum/pluginconf.d
    printf '[main]\nenabled=0\n' >/etc/dnf/plugins/subscription-manager.conf
    printf '[main]\nenabled=0\n' >/etc/yum/pluginconf.d/subscription-manager.conf
    rm -f /etc/yum.repos.d/redhat.repo

    cat >/etc/yum.repos.d/bazzite-offline-install-root.repo <<EOF
[bazzite-offline-baseos]
name=Bazzite Offline BaseOS
baseurl=file://${install_root}/BaseOS/
enabled=1
gpgcheck=0
repo_gpgcheck=0

[bazzite-offline-appstream]
name=Bazzite Offline AppStream
baseurl=file://${install_root}/AppStream/
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF

    dnf_repo_args=(--disablerepo='*' --enablerepo=bazzite-offline-baseos --enablerepo=bazzite-offline-appstream)
    if [[ -d ${install_root}/CRB/repodata ]]; then
        cat >>/etc/yum.repos.d/bazzite-offline-install-root.repo <<EOF

[bazzite-offline-crb]
name=Bazzite Offline CRB
baseurl=file://${install_root}/CRB/
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF
        dnf_repo_args+=(--enablerepo=bazzite-offline-crb)
    fi

    export BAZZITE_OFFLINE_INSTALL_MODE=true
    export BAZZITE_OFFLINE_INSTALL_ROOT=${install_root}
    export BAZZITE_OFFLINE_DNF_REPO_IDS=bazzite-offline-baseos,bazzite-offline-appstream
    if [[ -d ${install_root}/CRB/repodata ]]; then
        export BAZZITE_OFFLINE_DNF_REPO_IDS=${BAZZITE_OFFLINE_DNF_REPO_IDS},bazzite-offline-crb
    fi
}

dnf_install() {
    dnf "${dnf_repo_args[@]}" install -y "$@"
}

dnf_clean() {
    dnf "${dnf_repo_args[@]}" clean all
}

if [[ ${BASE_IMAGE,,} == *rhel* ]] && [[ -d /src/just_scripts/output/rhel-install-root/BaseOS/repodata ]] && [[ -d /src/just_scripts/output/rhel-install-root/AppStream/repodata ]]; then
    offline_install_root=/src/just_scripts/output/rhel-install-root
    offline_skip_flatpaks=true
    configure_offline_repos "${offline_install_root}"
    export BAZZITE_OFFLINE_SKIP_FLATPAKS=true
fi

# Create the directory that /root is symlinked to
mkdir -p "$(realpath /root)"

# bwrap tries to write /proc/sys/user/max_user_namespaces which is mounted as ro
# so we need to remount it as rw
mount -o remount,rw /proc/sys

# Install flatpaks when a local source is available.
mkdir -p /etc/flatpak/remotes.d /var/lib/flatpak
if [[ ${offline_skip_flatpaks} == true ]]; then
    mkdir -p /var/lib/flatpak_original
    sed -i '/^flatpak_remote = /d' /etc/anaconda/conf.d/anaconda.conf 2>/dev/null || true
else
    curl --retry 3 -Lo /etc/flatpak/remotes.d/flathub.flatpakrepo https://dl.flathub.org/repo/flathub.flatpakrepo
    xargs -r flatpak install -y --noninteractive <"/src/$FLATPAK_DIR_SHORTNAME/flatpaks"

    # Make a copy of the original flatpak files in order to avoid being altered by users on the live session
    cp -aT /var/lib/flatpak{,_original}
fi

# Pull the container image to be installed
if mountpoint -q /usr/lib/containers/storage; then
    # We load our image from the host container storage if possible
    podman save --format oci-archive "$INSTALL_IMAGE_PAYLOAD" | podman load --storage-opt additionalimagestore=''
else
    podman pull "$INSTALL_IMAGE_PAYLOAD"
fi

# Run the preinitramfs hook
"$SCRIPT_DIR/titanoboa_hook_preinitramfs.sh"

# Install dracut-live and regenerate the initramfs
dnf_install dracut-live
kernel=$(kernel-install list --json pretty | jq -r '.[] | select(.has_kernel == true) | .version')
DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"

# Install livesys-scripts and configure them
dnf_install livesys-scripts
if [[ ${BASE_IMAGE} == *-gnome* ]]; then
    sed -i "s/^livesys_session=.*/livesys_session=gnome/" /etc/sysconfig/livesys
else
    sed -i "s/^livesys_session=.*/livesys_session=kde/" /etc/sysconfig/livesys
fi
systemctl enable livesys.service livesys-late.service

# Run the postrootfs hook
"$SCRIPT_DIR/titanoboa_hook_postrootfs.sh"

# image-builder needs gcdx64.efi
dnf_install grub2-efi-x64-cdboot

# image-builder expects the EFI directory to be in /boot/efi
mkdir -p /boot/efi
cp -av /usr/lib/efi/*/*/EFI /boot/efi/

# Remove fallback efi
cp -v /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/fbx64.efi # NOTE: remove this line if breaks bootloader

# Set the timezone to UTC
rm -f /etc/localtime
systemd-firstboot --timezone UTC

# / in a booted live ISO is an overlayfs with upperdir pointed somewhere under /run
# This means that /var/tmp is also technically under /run.
# /run is of course a tmpfs, but set with quite a small size.
# ostree needs quite a lot of space on /var/tmp for temporary files so /run is not enough.
# Mount a larger tmpfs to /var/tmp at boot time to avoid this issue.
rm -rf /var/tmp
mkdir /var/tmp
cat >/etc/systemd/system/var-tmp.mount <<'EOF'
[Unit]
Description=Larger tmpfs for /var/tmp on live system

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=50%%,nr_inodes=1m,x-systemd.graceful-option=usrquota

[Install]
WantedBy=local-fs.target
EOF
systemctl enable var-tmp.mount

# Copy in the iso config for image-builder
mkdir -p /usr/lib/bootc-image-builder
cp /src/iso.yaml /usr/lib/bootc-image-builder/iso.yaml

# Clean up dnf cache to save space
dnf_clean

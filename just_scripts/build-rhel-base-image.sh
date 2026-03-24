#!/usr/bin/bash
set -eo pipefail

if [[ -z ${project_root:-} ]]; then
    project_root=$(git rev-parse --show-toplevel)
fi
if [[ -z ${git_branch:-} ]]; then
    git_branch=$(git branch --show-current)
fi

git_branch_tag=${git_branch//\//-}
git_branch_tag=${git_branch_tag//[^a-zA-Z0-9_.-]/-}

target=$1
image=$2

# shellcheck disable=SC2154,SC1091
. "${project_root}/just_scripts/get-defaults.sh"
# shellcheck disable=SC1091
. "${project_root}/just_scripts/sudoif.sh"

log() {
    echo "[build-rhel-base] $*" >&2
}

die() {
    log "$*"
    exit 1
}

require_command() {
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
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

    for repo_name in BaseOS AppStream; do
        [[ -d "${install_root}/${repo_name}/repodata" ]] || die "RHEL install root is missing ${repo_name}/repodata: ${install_root}"
    done
}

if [[ ${base_image_name} != "rhel-10" ]]; then
    die "This helper only supports RHEL 10 builds."
fi

require_command dnf5
require_command sha256sum
require_command tar
require_command rsync
require_command mktemp

container_mgr=$(just _container_mgr)

if [[ -n ${BAZZITE_RHEL_INSTALL_ISO:-} && -n ${BAZZITE_RHEL_INSTALL_ROOT:-} ]]; then
    die "Set either BAZZITE_RHEL_INSTALL_ISO or BAZZITE_RHEL_INSTALL_ROOT, not both."
fi

if [[ -z ${BAZZITE_RHEL_INSTALL_ISO:-} && -z ${BAZZITE_RHEL_INSTALL_ROOT:-} ]]; then
    die "Set BAZZITE_RHEL_INSTALL_ISO or BAZZITE_RHEL_INSTALL_ROOT before building the RHEL base image."
fi

staged_install_root="${project_root}/just_scripts/output/rhel-install-root"
rm -rf "${staged_install_root}"
mkdir -p "${staged_install_root}"

if [[ -n ${BAZZITE_RHEL_INSTALL_ISO:-} ]]; then
    require_command xorriso

    install_iso=$(readlink -f "${BAZZITE_RHEL_INSTALL_ISO}")
    [[ -f ${install_iso} ]] || die "RHEL install ISO not found: ${BAZZITE_RHEL_INSTALL_ISO}"

    log "Extracting install tree from ${install_iso}"
    xorriso -osirrox on -indev "${install_iso}" -extract / "${staged_install_root}" >/dev/null

    install_source_kind="iso"
    install_source_id=$(basename "${install_iso}")
    install_source_sha256=$(sha256sum "${install_iso}" | awk '{print $1}')
else
    install_root=$(readlink -f "${BAZZITE_RHEL_INSTALL_ROOT}")
    [[ -d ${install_root} ]] || die "RHEL install root not found: ${BAZZITE_RHEL_INSTALL_ROOT}"

    log "Copying install tree from ${install_root}"
    rsync -a --delete "${install_root}/" "${staged_install_root}/"

    install_source_kind="tree"
    install_source_id=$(basename "${install_root}")
    install_source_sha256=$(hash_install_root "${staged_install_root}")
fi

validate_install_root "${staged_install_root}"

workdir=$(mktemp -d "${TMPDIR:-/tmp}/bazzite-rhel-base.XXXXXX")
trap 'sudoif rm -rf "${workdir}"' EXIT

reposdir="${workdir}/repos.d"
rootfs="${workdir}/rootfs"
context_dir="${workdir}/context"
rootfs_tar="${context_dir}/rootfs.tar"
mkdir -p "${reposdir}" "${rootfs}" "${context_dir}"

cat > "${reposdir}/bazzite-rhel-install-root.repo" <<EOF
[bazzite-rhel-baseos]
name=Bazzite RHEL BaseOS
baseurl=file://${staged_install_root}/BaseOS/
enabled=1
gpgcheck=0
repo_gpgcheck=0

[bazzite-rhel-appstream]
name=Bazzite RHEL AppStream
baseurl=file://${staged_install_root}/AppStream/
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF

enabled_repos=(bazzite-rhel-baseos bazzite-rhel-appstream)
if [[ -d ${staged_install_root}/CRB/repodata ]]; then
    cat >> "${reposdir}/bazzite-rhel-install-root.repo" <<EOF

[bazzite-rhel-crb]
name=Bazzite RHEL CRB
baseurl=file://${staged_install_root}/CRB/
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF
    enabled_repos+=(bazzite-rhel-crb)
fi

repo_args=()
for repo in "${enabled_repos[@]}"; do
    repo_args+=(--enablerepo="${repo}")
done

package_args=(
    @core
    bootc
    dnf-bootc
    rpm-ostree
    kernel
    kernel-core
    kernel-modules
    dracut
    dracut-network
    NetworkManager
    podman
    skopeo
    ostree
    sudo
    passwd
    policycoreutils
    selinux-policy-targeted
    efibootmgr
    grub2-efi-x64
    shim-x64
)

log "Installing RHEL base filesystem from local ISO-backed repos"
sudoif dnf5 -y \
    --installroot "${rootfs}" \
    --releasever "${build_version}" \
    --setopt=install_weak_deps=False \
    --setopt=reposdir="${reposdir}" \
    --setopt=cachedir="${workdir}/dnf-cache" \
    --disablerepo='*' \
    --nogpgcheck \
    "${repo_args[@]}" \
    install "${package_args[@]}" >&2

sudoif dnf5 -y \
    --installroot "${rootfs}" \
    --releasever "${build_version}" \
    --setopt=reposdir="${reposdir}" \
    --disablerepo='*' \
    clean all >&2

if [[ -f ${rootfs}/etc/machine-id ]]; then
    sudoif truncate -s 0 "${rootfs}/etc/machine-id"
fi
sudoif rm -rf "${rootfs}/var/cache"/* "${rootfs}/var/log"/* || true

log "Packing root filesystem"
sudoif tar --xattrs --acls --selinux --numeric-owner -C "${rootfs}" -cf "${rootfs_tar}" .

cat > "${context_dir}/Containerfile" <<EOF
FROM scratch
ADD rootfs.tar /
LABEL org.bazzite.rhel-install-source-kind="${install_source_kind}"
LABEL org.bazzite.rhel-install-source-id="${install_source_id}"
LABEL org.bazzite.rhel-install-source-sha256="${install_source_sha256}"
CMD ["/sbin/init"]
EOF

base_image_ref="${BAZZITE_RHEL_BASE_IMAGE_OUTPUT:-localhost/bazzite-rhel-10-base:rhel10}"
versioned_base_ref="localhost/bazzite-rhel-10-base:${build_version}-${git_branch_tag}"

log "Building local base image ${base_image_ref}"
"${container_mgr}" build \
    -f "${context_dir}/Containerfile" \
    -t "${base_image_ref}" \
    -t "${versioned_base_ref}" \
    "${context_dir}" >&2

printf '%s\n' "${base_image_ref}"
#!/usr/bin/bash
set -euo pipefail

image_ref=${1:-}
container_mgr=${2:-podman}

if [[ -z ${image_ref} ]]; then
    echo "Usage: $0 <image-ref> [container-manager]" >&2
    exit 2
fi

container_id=$(
    "${container_mgr}" create \
        --entrypoint /bin/bash \
        "${image_ref}" \
        -lc '
            set -euo pipefail
            installed_rhsm_packages=()
            for package_name in \
                rhc \
                insights-client \
                insights-core \
                libdnf-plugin-subscription-manager \
                python3-subscription-manager-rhsm \
                subscription-manager \
                subscription-manager-cockpit \
                subscription-manager-plugin-ostree \
                subscription-manager-rhsm-certificates
            do
                if rpm -q "${package_name}" >/dev/null 2>&1; then
                    installed_rhsm_packages+=("${package_name}")
                fi
            done

            if (( ${#installed_rhsm_packages[@]} > 0 )); then
                rpm -e "${installed_rhsm_packages[@]}"
            fi

            rm -f /etc/yum.repos.d/redhat.repo
            mkdir -p /etc/dnf/plugins /etc/yum/pluginconf.d
            printf "[main]\nenabled=0\n" > /etc/dnf/plugins/subscription-manager.conf
            printf "[main]\nenabled=0\n" > /etc/yum/pluginconf.d/subscription-manager.conf
        '
)

cleanup() {
    "${container_mgr}" rm -f "${container_id}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

"${container_mgr}" start -a "${container_id}" >/dev/null
"${container_mgr}" commit "${container_id}" "${image_ref}" >/dev/null

echo "Sanitized ${image_ref} for offline RHEL use" >&2
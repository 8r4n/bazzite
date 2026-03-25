#!/usr/bin/bash
set -euo pipefail

image_ref=${1:-}
container_mgr=${2:-podman}

if [[ -z ${image_ref} ]]; then
    echo "Usage: $0 <image-ref> [container-manager]" >&2
    exit 2
fi

tmp_tar=$(mktemp "${TMPDIR:-/tmp}/bazzite-rhel-image.XXXXXX.tar")
container_id=

cleanup() {
    local exit_code=$?
    rm -f "${tmp_tar}"
    if [[ -n ${container_id} ]]; then
        "${container_mgr}" rm -f "${container_id}" >/dev/null 2>&1 || true
    fi
    exit ${exit_code}
}

trap cleanup EXIT

container_id=$("${container_mgr}" create --entrypoint /bin/sh "${image_ref}" -lc 'true')
"${container_mgr}" export -o "${tmp_tar}" "${container_id}" >/dev/null

if tar -tf "${tmp_tar}" | grep -qx 'etc/yum.repos.d/redhat.repo'; then
    echo "RHEL offline build regression: etc/yum.repos.d/redhat.repo is present in ${image_ref}" >&2
    exit 1
fi

for conf_path in etc/dnf/plugins/subscription-manager.conf etc/yum/pluginconf.d/subscription-manager.conf; do
    if tar -tf "${tmp_tar}" | grep -qx "${conf_path}"; then
        conf_content=$(tar -xOf "${tmp_tar}" "${conf_path}")
        if ! grep -Eq '^enabled=0$' <<<"${conf_content}"; then
            echo "RHEL offline build regression: ${conf_path} is not disabled in ${image_ref}" >&2
            exit 1
        fi
    fi
done

container_id=$("${container_mgr}" create --entrypoint /usr/bin/rpm "${image_ref}" -q \
    subscription-manager \
    libdnf-plugin-subscription-manager \
    python3-subscription-manager-rhsm \
    insights-client \
    insights-core \
    rhc \
    subscription-manager-cockpit \
    subscription-manager-plugin-ostree \
    subscription-manager-rhsm-certificates 2>/dev/null || true)
if [[ -n ${container_id} ]]; then
    "${container_mgr}" rm -f "${container_id}" >/dev/null 2>&1 || true
fi

package_output=$("${container_mgr}" run --rm --pull=never --entrypoint /usr/bin/rpm "${image_ref}" -q \
    subscription-manager \
    libdnf-plugin-subscription-manager \
    python3-subscription-manager-rhsm \
    insights-client \
    insights-core \
    rhc \
    subscription-manager-cockpit \
    subscription-manager-plugin-ostree \
    subscription-manager-rhsm-certificates 2>&1 || true)
if grep -Evq 'package .* is not installed|not installed$|^$' <<<"${package_output}"; then
    echo "RHEL offline build regression: RHSM-managed packages remain in ${image_ref}" >&2
    printf '%s\n' "${package_output}" >&2
    exit 1
fi

echo "Verified offline RHEL repo state for ${image_ref}" >&2
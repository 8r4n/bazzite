#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: validate-iso-boot.sh --iso <path> [options]

Boot an installer/live ISO in QEMU and verify it reaches a functioning Linux userspace.

Options:
  --iso <path>            Path to ISO file (required)
  --mode <auto|anaconda|live>
                          Boot mode to validate. Default: auto
  --label <string>        Override ISO volume label (used for stage2/root=live). Default: auto-detect
  --timeout <seconds>     Max seconds to wait for successful boot. Default: 900
  --ram <MiB>             QEMU RAM in MiB. Default: 4096
  --cpus <count>          QEMU vCPU count. Default: 2
  --keep-logs             Keep temporary directory (prints path)
  --help                  Show this help

Requirements:
  - qemu-system-x86_64
  - xorriso
  - timeout
EOF
}

log() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "${value}"
}

iso_path=
mode=auto
volume_label=
timeout_s=900
ram_mib=4096
cpu_count=2
keep_logs=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            iso_path=${2:-}
            shift 2
            ;;
        --mode)
            mode=${2:-}
            shift 2
            ;;
        --label)
            volume_label=${2:-}
            shift 2
            ;;
        --timeout)
            timeout_s=${2:-}
            shift 2
            ;;
        --ram)
            ram_mib=${2:-}
            shift 2
            ;;
        --cpus)
            cpu_count=${2:-}
            shift 2
            ;;
        --keep-logs)
            keep_logs=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "${iso_path}" ]] || { usage; exit 2; }
[[ -f "${iso_path}" ]] || die "ISO not found: ${iso_path}"

case "${mode}" in
    auto|anaconda|live) ;;
    *) die "Invalid --mode '${mode}' (expected auto|anaconda|live)" ;;
esac

require_cmd qemu-system-x86_64
require_cmd xorriso
require_cmd timeout

workdir="$(mktemp -d -p /tmp validate-iso-boot.XXXXXX)"
# shellcheck disable=SC2317
cleanup() {
    if [[ "${keep_logs}" == true ]]; then
        log "Keeping logs at ${workdir}"
        return
    fi
    rm -rf "${workdir}"
}
trap cleanup EXIT

detect_volume_label() {
    local label
    label="$(
        xorriso -indev "${iso_path}" -pvd_info 2>/dev/null \
            | awk -F: 'tolower($1) ~ /volume id/ { sub(/^[[:space:]]+/, "", $2); print $2; exit }'
    )"
    label="$(trim "${label}")"
    if [[ -z "${label}" ]]; then
        return 1
    fi
    printf '%s' "${label}"
}

iso_has_path() {
    local iso_check_path=$1
    xorriso -indev "${iso_path}" -find "${iso_check_path}" -maxdepth 0 -type f -print 2>/dev/null | grep -q .
}

auto_detect_mode() {
    if iso_has_path /LiveOS/squashfs.img; then
        printf '%s' live
        return 0
    fi
    printf '%s' anaconda
}

if [[ -z "${volume_label}" ]]; then
    if ! volume_label="$(detect_volume_label)"; then
        die "Unable to auto-detect ISO label; pass --label"
    fi
fi

if [[ "${mode}" == auto ]]; then
    mode="$(auto_detect_mode)"
fi

log "ISO: ${iso_path}"
log "Mode: ${mode}"
log "Label: ${volume_label}"

kernel_path="${workdir}/vmlinuz"
initrd_path="${workdir}/initrd.img"
serial_log="${workdir}/serial.log"

extract_boot_artifacts() {
    xorriso -osirrox on -indev "${iso_path}" -extract /images/pxeboot/vmlinuz "${kernel_path}" >/dev/null 2>&1 \
        || die "Failed to extract /images/pxeboot/vmlinuz from ISO"
    xorriso -osirrox on -indev "${iso_path}" -extract /images/pxeboot/initrd.img "${initrd_path}" >/dev/null 2>&1 \
        || die "Failed to extract /images/pxeboot/initrd.img from ISO"
}

extract_boot_artifacts

boot_args_common=(
    "console=ttyS0,115200n8"
    rd.systemd.show_status=1
    systemd.show_status=1
    loglevel=4
)

boot_args=()
success_patterns=()

if [[ "${mode}" == live ]]; then
    boot_args+=(
        "${boot_args_common[@]}"
        rd.live.image
        "root=live:CDLABEL=${volume_label}"
        enforcing=0
        systemd.unit=multi-user.target
    )
    success_patterns+=(
        'Linux version '
        'systemd\\[[0-9]+\\]: Reached target .*System'
        'systemd\\[[0-9]+\\]: Started .*'
        'Welcome to '
    )
else
    boot_args+=(
        "${boot_args_common[@]}"
        inst.text
        "inst.stage2=hd:LABEL=${volume_label}"
        inst.loglevel=debug
    )
    success_patterns+=(
        'Linux version '
        'Starting installer'
        'anaconda'
        'Running.*Anaconda'
    )
fi

log "Extracted kernel/initrd to ${workdir}"
log "Boot args: ${boot_args[*]}"

qemu_cmd=(
    qemu-system-x86_64
    -machine q35
    -accel tcg
    -cpu max
    -m "${ram_mib}"
    -smp "${cpu_count}"
    -nographic
    -no-reboot
    -net none
    -drive "file=${iso_path},media=cdrom,readonly=on"
    -kernel "${kernel_path}"
    -initrd "${initrd_path}"
    -append "$(printf '%s ' "${boot_args[@]}")"
)

log "Starting QEMU..."

(
    if command -v stdbuf >/dev/null 2>&1; then
        exec stdbuf -oL -eL "${qemu_cmd[@]}"
    fi
    exec "${qemu_cmd[@]}"
) >"${serial_log}" 2>&1 &

qemu_pid=$!

kill_qemu() {
    if kill -0 "${qemu_pid}" 2>/dev/null; then
        kill "${qemu_pid}" 2>/dev/null || true
        wait "${qemu_pid}" 2>/dev/null || true
    fi
}
trap kill_qemu INT TERM

deadline=$((SECONDS + timeout_s))
matched=

while (( SECONDS < deadline )); do
    if ! kill -0 "${qemu_pid}" 2>/dev/null; then
        break
    fi

    for pattern in "${success_patterns[@]}"; do
        if grep -Eq "${pattern}" "${serial_log}" 2>/dev/null; then
            matched=${pattern}
            break
        fi
    done

    if [[ -n "${matched}" ]]; then
        break
    fi

    sleep 1
done

if [[ -n "${matched}" ]]; then
    log "Boot validation passed (matched: ${matched})"
    kill_qemu
    exit 0
fi

log "Boot validation failed (timeout=${timeout_s}s). Showing last 200 log lines:"
tail -n 200 "${serial_log}" || true
kill_qemu
exit 1

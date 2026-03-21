#!/usr/bin/env bash

set -euo pipefail

: "${DHCP_RANGE:=192.168.100.100,192.168.100.199,255.255.255.0,12h}"
: "${DHCP_ROUTER:=192.168.100.1}"
: "${PXE_SERVER_IP:=192.168.100.2}"
: "${HTTP_PORT:=8080}"
: "${CENTOS_INSTALL_ROOT:=http://mirror.stream.centos.org/10-stream/BaseOS/x86_64/os}"
: "${KICKSTART_PATH:=/kickstarts/centos-ostree.ks}"

mkdir -p /srv/tftp/pxelinux.cfg

for asset in lpxelinux.0 ldlinux.c32 libcom32.c32 libutil.c32 menu.c32; do
    if [[ -f "/usr/share/syslinux/${asset}" ]]; then
        cp -f "/usr/share/syslinux/${asset}" "/srv/tftp/${asset}"
    fi
done

cat >/srv/tftp/pxelinux.cfg/default <<EOF
DEFAULT centos-ostree
PROMPT 0
TIMEOUT 50

LABEL centos-ostree
    MENU LABEL Install CentOS Stream rpm-ostree node
    KERNEL ${CENTOS_INSTALL_ROOT}/images/pxeboot/vmlinuz
    APPEND initrd=${CENTOS_INSTALL_ROOT}/images/pxeboot/initrd.img ip=dhcp inst.repo=${CENTOS_INSTALL_ROOT} inst.stage2=${CENTOS_INSTALL_ROOT} inst.ks=http://${PXE_SERVER_IP}:${HTTP_PORT}${KICKSTART_PATH}
EOF

cat >/etc/dnsmasq.d/pxe.conf <<EOF
port=0
log-dhcp
dhcp-authoritative
dhcp-range=${DHCP_RANGE}
dhcp-option=option:router,${DHCP_ROUTER}
enable-tftp
tftp-root=/srv/tftp
dhcp-boot=lpxelinux.0
EOF

exec dnsmasq --keep-in-foreground --log-facility=-

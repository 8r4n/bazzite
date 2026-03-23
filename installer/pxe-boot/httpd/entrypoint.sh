#!/usr/bin/env bash

set -euo pipefail

: "${HTTP_PORT:=8080}"
: "${DEPLOYMENT_TYPE:=ostree}"
: "${OSTREE_REPO_URL:=http://192.168.100.2:8080/ostree/repo}"
: "${OSTREE_REMOTE:=centos}"
: "${OSTREE_OSNAME:=centos}"
: "${OSTREE_REF:=centos-stream/10/x86_64/edge}"
: "${OSTREE_CONTAINER_URL:=ghcr.io/example/bazzite-custom-gnome-c10s:stable}"
: "${OSTREE_CONTAINER_TRANSPORT:=registry}"
: "${OSTREE_CONTAINER_NO_SIGNATURE_VERIFICATION:=false}"

mkdir -p /srv/www/kickstarts /srv/www/ostree/repo

case "${DEPLOYMENT_TYPE}" in
	ostree)
		install_directive="ostreesetup --osname=${OSTREE_OSNAME} --remote=${OSTREE_REMOTE} --url=${OSTREE_REPO_URL} --ref=${OSTREE_REF}"
		;;
	container)
		install_directive="ostreecontainer --url=${OSTREE_CONTAINER_URL} --transport=${OSTREE_CONTAINER_TRANSPORT}"
		if [[ ${OSTREE_CONTAINER_NO_SIGNATURE_VERIFICATION} == "1" || ${OSTREE_CONTAINER_NO_SIGNATURE_VERIFICATION,,} == "true" ]]; then
			install_directive+=" --no-signature-verification"
		fi
		;;
	*)
		echo "Unsupported DEPLOYMENT_TYPE: ${DEPLOYMENT_TYPE}. Expected 'ostree' or 'container'." >&2
		exit 1
		;;
esac

	kickstart_path=/srv/www/kickstarts/centos-ostree.ks

	cat >"${kickstart_path}" <<EOF
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate
rootpw --lock
firewall --enabled --service=ssh
services --enabled=sshd
zerombr
clearpart --all --initlabel
autopart --type=plain
reboot

${install_directive}

%packages
@core
%end
EOF

if [[ ${DEPLOYMENT_TYPE} == "container" ]]; then
	cp -f "${kickstart_path}" /srv/www/kickstarts/centos-container.ks
fi

exec python3 -m http.server "${HTTP_PORT}" --bind 0.0.0.0 --directory /srv/www

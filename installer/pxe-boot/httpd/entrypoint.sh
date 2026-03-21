#!/usr/bin/env bash

set -euo pipefail

: "${HTTP_PORT:=8080}"
: "${OSTREE_REPO_URL:=http://192.168.100.2:8080/ostree/repo}"
: "${OSTREE_REMOTE:=centos}"
: "${OSTREE_OSNAME:=centos}"
: "${OSTREE_REF:=centos-stream/10/x86_64/edge}"

mkdir -p /srv/www/kickstarts /srv/www/ostree/repo

cat >/srv/www/kickstarts/centos-ostree.ks <<EOF
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

ostreesetup --osname=${OSTREE_OSNAME} --remote=${OSTREE_REMOTE} --url=${OSTREE_REPO_URL} --ref=${OSTREE_REF}

%packages
@core
%end
EOF

exec python3 -m http.server "${HTTP_PORT}" --bind 0.0.0.0 --directory /srv/www

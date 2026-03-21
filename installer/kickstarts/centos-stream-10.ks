# Kickstart for deploying the CentOS Stream 10 rpm-ostree image built by this repository.
#
# Update the ostreecontainer image reference below if you publish the image under a different
# registry, namespace, or tag.

text
lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --lock
selinux --enforcing
firewall --enabled --service=ssh
services --enabled=sshd
reboot

clearpart --all --initlabel
autopart --type=btrfs --noswap

ostreecontainer --url=ghcr.io/8r4n/bazzite-custom-gnome-c10s:stable --transport=registry --no-signature-verification

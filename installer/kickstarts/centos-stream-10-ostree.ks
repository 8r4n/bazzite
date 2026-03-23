# Kickstart for deploying a CentOS Stream 10 system from a plain OSTree repository.
#
# Update the URL, remote, osname, and ref values below to match the repository you publish for PXE
# or HTTP-based installations.

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
autopart --type=btrfs

ostreesetup --osname=centos --remote=centos --url=http://192.168.100.2:8080/ostree/repo --ref=centos-stream/10/x86_64/edge
# Kickstart for deploying the CentOS Stream 10 rpm-ostree image built by this repository.
#
# Replace <your-github-owner> below with the GitHub username or organization that publishes your
# image before using this kickstart. Adjust the registry or tag as needed for your deployment.

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

# Replace <your-github-owner> with the GitHub user or organization that publishes your image.
ostreecontainer --url=ghcr.io/<your-github-owner>/bazzite-custom-gnome-c10s:stable --transport=registry

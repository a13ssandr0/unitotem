#!/bin/bash -e

install -v -m 644 files/start-xorg.service "${ROOTFS_DIR}/etc/systemd/system/"
install -v -m 644 files/iptables-firewall.service "${ROOTFS_DIR}/etc/systemd/system/"
install -v -m 755 files/xinitrc "${ROOTFS_DIR}/etc/X11/xinit/"
install -v -m 750 files/iptables-firewall.sh "${ROOTFS_DIR}/sbin/"

curl -s --compressed -o "${ROOTFS_DIR}/etc/apt/trusted.gpg.d/unitotem-manager.asc" "https://a13ssandr0.github.io/unitotem-manager/KEY.gpg"
curl -s --compressed -o "${ROOTFS_DIR}/etc/apt/sources.list.d/unitotem-manager.list" "https://a13ssandr0.github.io/unitotem-manager/unitotem-manager.list"

on_chroot << EOF
# if rerunning the script, it attempts to create the user and finds out it already exists, fails safely
adduser --disabled-password --gecos "" unitotem || true
systemctl enable start-xorg.service
systemctl enable iptables-firewall.service
apt-get update
apt-get -o APT::Acquire::Retries=3 install -y unitotem-manager
EOF

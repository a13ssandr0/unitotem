#!/bin/bash -e

install -v -m 644 files/start-xorg.service "${ROOTFS_DIR}/etc/systemd/system/"
install -v -m 755 files/xinitrc "${ROOTFS_DIR}/etc/X11/xinit/"

curl -s --compressed -o "${ROOTFS_DIR}/etc/apt/trusted.gpg.d/unitotem-manager.asc" "https://a13ssandr0.github.io/unitotem-manager/KEY.gpg"
curl -s --compressed -o "${ROOTFS_DIR}/etc/apt/sources.list.d/unitotem-manager.list" "https://a13ssandr0.github.io/unitotem-manager/unitotem-manager.list"

on_chroot << EOF
# if rerunning the script, it attempts to create the user and finds out it already exists, fails safely
adduser --disabled-password --gecos "" unitotem || true
systemctl enable start-xorg.service
apt-get update
apt-get -o APT::Acquire::Retries=3 install -y unitotem-manager
EOF


# Enable iptables firewall and allow ports 22, 80, 443 (disable because not working inside chroot)

# on_chroot << EOF
# iptables-nft -L -v                                                          # List rules (for debug)
# iptables-nft -F                                                             # Flush all current rules from iptables
# iptables-nft -P INPUT DROP                                                  # Set default policies for INPUT, FORWARD and OUTPUT chains
# iptables-nft -P FORWARD DROP
# iptables-nft -P OUTPUT ACCEPT
# iptables-nft -A INPUT -p tcp --dport 22 -j ACCEPT                           # Allow SSH connections on tcp port 22
# iptables-nft -A INPUT -p tcp --dport 80 -j ACCEPT                           # Allow SSH connections on tcp port 80
# iptables-nft -A INPUT -p tcp --dport 443 -j ACCEPT                          # Allow SSH connections on tcp port 443
# iptables-nft -A INPUT -i lo -j ACCEPT                                       # Set access for localhost
# iptables-nft -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT        # Accept packets belonging to established and related connections
# iptables-nft -L -v                                                          # List rules (for debug)
# /sbin/service iptables-nft save                                             # Save settings
# EOF
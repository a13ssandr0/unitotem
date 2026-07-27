#!/bin/bash
set -euo pipefail
source /kiosk/common.sh

echo "=== Stage 1: Package Installation (ARCH=${ARCH}) ==="

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

echo "Extracting stage 0..."
tar -C "${ROOTFS}" -xzf "${WORK_DIR}/stage0.tar.gz"

ensure_qemu
mount_chroot
install_policy_rc

# ---------- APT sources ----------

cat > "${ROOTFS}/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

if [ "$ARCH" = "arm64" ]; then
    curl -fsSL https://archive.raspberrypi.org/debian/raspberrypi.gpg.key \
        | gpg --dearmor > "${ROOTFS}/etc/apt/trusted.gpg.d/raspberrypi.gpg"
    echo "deb http://archive.raspberrypi.org/debian/ bookworm main" \
        > "${ROOTFS}/etc/apt/sources.list.d/raspi.list"
fi

# UniTotem Manager repository
curl -fsSL https://a13ssandr0.github.io/unitotem-manager/KEY.gpg \
    > "${ROOTFS}/etc/apt/trusted.gpg.d/unitotem-manager.asc"
curl -fsSL https://a13ssandr0.github.io/unitotem-manager/unitotem-manager.list \
    > "${ROOTFS}/etc/apt/sources.list.d/unitotem-manager.list"

chroot "${ROOTFS}" apt-get update

# ---------- Kernel + firmware + bootloader ----------

if [ "$ARCH" = "amd64" ]; then
    chroot "${ROOTFS}" apt-get install -y --no-install-recommends \
        linux-image-amd64 \
        firmware-linux \
        firmware-linux-nonfree \
        firmware-misc-nonfree \
        grub-efi-amd64 \
        efibootmgr

elif [ "$ARCH" = "arm64" ]; then
    chroot "${ROOTFS}" apt-get install -y --no-install-recommends \
        linux-image-arm64 \
        firmware-brcm80211 \
        firmware-linux \
        firmware-linux-nonfree \
        raspberrypi-bootloader \
        raspi-firmware
fi

# ---------- Base system ----------

chroot "${ROOTFS}" apt-get install -y \
    locales \
    sudo curl wget ca-certificates gnupg2 \
    openssh-server \
    iproute2 iputils-ping net-tools \
    htop nano less \
    util-linux e2fsprogs \
    lsb-release initramfs-tools apt-utils \
    dbus dbus-user-session libpam-systemd \
    systemd-timesyncd \
    network-manager netplan.io \
    python3 python3-dbus python3-gi python3-pyudev \
    gir1.2-glib-2.0 \
    iptables

# ---------- Plymouth ----------

chroot "${ROOTFS}" apt-get install -y \
    plymouth plymouth-themes libplymouth5 imagemagick

# ---------- GPU libraries (common) ----------

chroot "${ROOTFS}" apt-get install -y \
    libglvnd0 libglx0 libgles2 libvulkan1 \
    mesa-utils libgl1-mesa-dri

# ---------- GPU drivers (arch-specific) ----------

if [ "$ARCH" = "amd64" ]; then
    chroot "${ROOTFS}" apt-get install -y \
        intel-media-va-driver-non-free \
        i965-va-driver-shaders \
        libva2 libva-drm2 libva-wayland2 vainfo \
        mesa-vulkan-drivers \
        firmware-amd-graphics \
        mesa-va-drivers \
        libdrm-amdgpu1

elif [ "$ARCH" = "arm64" ]; then
    chroot "${ROOTFS}" apt-get install -y \
        libva2 libva-drm2 vainfo \
        v4l-utils libv4l-dev
fi

# ---------- X11 + PipeWire ----------
# No window manager: unitotem-manager's own Qt6+CEF viewer already sets its
# window to exact fullscreen geometry with no decorations on its own, and CEF
# only supports X11 embedding anyway (see manager/webview/window.py) - a bare
# Xorg session (no WM) is both sufficient and simpler than a Wayland
# compositor, which would still need XWayland underneath for CEF regardless.

chroot "${ROOTFS}" apt-get install -y \
    xserver-xorg xserver-xorg-video-all xserver-xorg-input-all \
    xinit x11-xserver-utils kbd \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    gstreamer1.0-pipewire gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav libspa-0.2-bluetooth

# ---------- UniTotem packages ----------

chroot "${ROOTFS}" apt-get install -y \
    python3-pip python3-apt python3-venv \
    libopenjp2-7-dev openssl mediainfo haproxy rfkill alsa-utils

chroot "${ROOTFS}" apt-get install -y unitotem-manager

# ---------- Clean up ----------

chroot "${ROOTFS}" apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"*

remove_policy_rc
umount_chroot

echo "Saving stage 1 tarball..."
tar -C "${ROOTFS}" -czf "${WORK_DIR}/stage1.tar.gz" .

echo "=== Stage 1 complete ==="

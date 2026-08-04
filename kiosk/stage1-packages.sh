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

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get update

# ---------- Kernel + firmware + bootloader ----------

if [ "$ARCH" = "amd64" ]; then
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        linux-image-amd64 \
        firmware-linux \
        firmware-linux-nonfree \
        firmware-misc-nonfree \
        grub-efi-amd64 \
        grub-pc-bin \
        efibootmgr

elif [ "$ARCH" = "arm64" ]; then
    # linux-image-rpi-v8, not the generic Debian linux-image-arm64: the
    # generic kernel's version string never matches raspi-firmware's own
    # z50-raspi-firmware postinst hook (flavour "${kver#*-rpi-}" only
    # recognises v8|v8-rt|2712|v6|v7|v7l), so that hook silently skipped
    # copying kernel8.img/initramfs8/dtbs, and it ships no overlays/ at all
    # (no KMS). The real rpi kernel fixes both: the hook now matches
    # natively (verified against the actual package - flavour resolves to
    # "v8", producing exactly kernel8.img/initramfs8, the filenames this
    # project already expects) and ships overlays/ including
    # vc4-kms-v3d(-pi5).dtbo, which kiosk/files/config.txt now enables. See
    # PLAN.md's arm64 follow-up section for the full history.
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        linux-image-rpi-v8 \
        firmware-brcm80211 \
        firmware-linux \
        firmware-linux-nonfree \
        raspberrypi-bootloader \
        raspi-firmware
fi

# ---------- OTA payload (deploy/ota-engine.sh, kiosk/files/ota-hook) ----------
# Installed in stage1 (not stage2) deliberately: kiosk/stage1-recovery-initrd.sh
# builds the resident fallback kernel+initrd straight from this rootfs right
# after this stage finishes, and stage2 builds the real system's own
# initramfs from the same base later - one package list covers both, so the
# fallback and the real system's initramfs are never out of sync with each
# other. gdisk/parted are not on the automated OTA restore path (sfdisk
# covers that) but are kept anyway for manual disaster recovery - see the
# OTA redesign plan, decisions table.
chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    partclone gdisk parted fdisk pv netcat-traditional dropbear-bin wpasupplicant whiptail dosfstools xz-utils

mkdir -p "${ROOTFS}/usr/lib/unitotem"
install -m 755 /kiosk/files/ota-engine.sh "${ROOTFS}/usr/lib/unitotem/ota-engine.sh"
ln -sf /usr/lib/unitotem/ota-engine.sh "${ROOTFS}/usr/sbin/unitotem-ota-engine"

install -m 755 /kiosk/files/ota-hook "${ROOTFS}/etc/initramfs-tools/hooks/unitotem-ota"
mkdir -p "${ROOTFS}/etc/unitotem"

# ---------- Base system ----------

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    locales \
    sudo curl wget ca-certificates gnupg2 \
    openssh-server \
    iproute2 iputils-ping net-tools \
    htop nano less \
    util-linux udev e2fsprogs \
    lsb-release initramfs-tools apt-utils \
    dbus dbus-user-session libpam-systemd \
    systemd-timesyncd \
    network-manager netplan.io \
    python3 python3-dbus python3-gi python3-pyudev \
    gir1.2-glib-2.0 \
    iptables

# ---------- Plymouth ----------

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    plymouth plymouth-themes plymouth-label libplymouth5

# ---------- GPU libraries (common) ----------

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libglvnd0 libglx0 libgles2 libvulkan1 \
    mesa-utils libgl1-mesa-dri

# ---------- GPU drivers (arch-specific) ----------

if [ "$ARCH" = "amd64" ]; then
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        intel-media-va-driver-non-free \
        i965-va-driver-shaders \
        libva2 libva-drm2 libva-wayland2 vainfo \
        mesa-vulkan-drivers \
        firmware-amd-graphics \
        mesa-va-drivers \
        libdrm-amdgpu1

elif [ "$ARCH" = "arm64" ]; then
    # Note for anyone reading the list below: libva/vainfo are INERT on a
    # Raspberry Pi. VideoCore has no VAAPI driver - hardware video decode is
    # reached through V4L2 mem2mem devices instead (/dev/video10
    # "bcm2835-codec-decode" for H.264 on every model, plus /dev/video19
    # "rpi-hevc-dec" for HEVC on Pi 4 and later only). They are kept purely
    # because the amd64 branch above shares consumers with them; do not read
    # their presence as VAAPI being available here.
    #
    # gstreamer1.0-tools provides gst-inspect/gst-launch, which is how one
    # actually confirms those V4L2 decoders are exposed to the media stack -
    # without it the question can only be answered by guesswork.
    #
    # raspi-utils provides vcgencmd, and that is not a nicety: it is the only
    # way to see whether the board is thermally or voltage throttled. On a
    # kiosk "the video stutters" and "the PSU is undersized" look identical
    # from every other angle.
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        libva2 libva-drm2 vainfo \
        v4l-utils libv4l-dev \
        gstreamer1.0-tools \
        raspi-utils
fi

# ---------- X11 + PipeWire ----------
# No window manager: unitotem-manager's own Qt6+CEF viewer already sets its
# window to exact fullscreen geometry with no decorations on its own, and CEF
# only supports X11 embedding anyway (see manager/webview/window.py) - a bare
# Xorg session (no WM) is both sufficient and simpler than a Wayland
# compositor, which would still need XWayland underneath for CEF regardless.

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    xserver-xorg xserver-xorg-video-all xserver-xorg-input-all \
    xinit x11-xserver-utils kbd \
    pipewire pipewire-audio pipewire-pulse pipewire-jack pipewire-alsa \
    wireplumber libpipewire-0.3-0 \
    gstreamer1.0-pipewire gstreamer1.0-vaapi \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav libspa-0.2-bluetooth

# ---------- UniTotem packages ----------

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3-pip python3-apt python3-venv \
    libopenjp2-7-dev openssl mediainfo haproxy rfkill alsa-utils

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y unitotem-manager

# ---------- Clean up ----------

chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get clean
rm -rf "${ROOTFS}/var/lib/apt/lists/"*

remove_policy_rc
umount_chroot

echo "Saving stage 1 tarball..."
tar -C "${ROOTFS}" -czf "${WORK_DIR}/stage1.tar.gz" .

echo "=== Stage 1 complete ==="

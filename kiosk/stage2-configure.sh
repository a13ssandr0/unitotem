#!/bin/bash
set -euo pipefail
source /kiosk/common.sh

echo "=== Stage 2: System Configuration (ARCH=${ARCH}) ==="

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

echo "Extracting stage 1..."
tar -C "${ROOTFS}" -xzf "${WORK_DIR}/stage1.tar.gz"

ensure_qemu
mount_chroot

# ---------- Hostname ----------

echo "${KIOSK_HOSTNAME}" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${KIOSK_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# ---------- Locale ----------

sed -i "s/# ${KIOSK_LOCALE} UTF-8/${KIOSK_LOCALE} UTF-8/" "${ROOTFS}/etc/locale.gen"
chroot "${ROOTFS}" locale-gen
echo "LANG=${KIOSK_LOCALE}" > "${ROOTFS}/etc/locale.conf"

# ---------- Timezone ----------

ln -sf "/usr/share/zoneinfo/${KIOSK_TIMEZONE}" "${ROOTFS}/etc/localtime"
chroot "${ROOTFS}" dpkg-reconfigure -f noninteractive tzdata

# ---------- Root password ----------

chroot "${ROOTFS}" bash -c "echo 'root:${ROOT_PASSWORD}' | chpasswd"

# ---------- SSH ----------

install -m 644 /kiosk/files/sshd_config "${ROOTFS}/etc/ssh/sshd_config"
mkdir -p "${ROOTFS}/root/.ssh"
chmod 700 "${ROOTFS}/root/.ssh"

# ---------- Plymouth theme ----------

mkdir -p "${ROOTFS}/usr/share/plymouth/themes/kiosk"
install -m 644 /kiosk/files/kiosk.plymouth "${ROOTFS}/usr/share/plymouth/themes/kiosk/"
install -m 644 /kiosk/files/kiosk.script   "${ROOTFS}/usr/share/plymouth/themes/kiosk/"

chroot "${ROOTFS}" convert -size 256x256 xc:none \
    -fill 'rgba(34,130,242,0.9)' \
    -draw 'roundrectangle 20,20,235,235,30,30' \
    /usr/share/plymouth/themes/kiosk/logo.png

chroot "${ROOTFS}" update-alternatives --install \
    /usr/share/plymouth/themes/default.plymouth \
    default.plymouth \
    /usr/share/plymouth/themes/kiosk/kiosk.plymouth \
    100
chroot "${ROOTFS}" plymouth-set-default-theme kiosk

mkdir -p "${ROOTFS}/etc/plymouth"
install -m 644 /kiosk/files/plymouthd.conf "${ROOTFS}/etc/plymouth/plymouthd.conf"

# ---------- Bootloader configuration ----------

if [ "$ARCH" = "amd64" ]; then
    install -m 644 /kiosk/files/grub-default "${ROOTFS}/etc/default/grub"
fi

if [ "$ARCH" = "arm64" ]; then
    mkdir -p "${ROOTFS}/boot/firmware"
    install -m 644 /kiosk/files/config.txt "${ROOTFS}/boot/firmware/config.txt"
    echo "console=tty1 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet splash loglevel=3 rd.systemd.show_status=false plymouth.ignore-serial-consoles" \
        > "${ROOTFS}/boot/firmware/cmdline.txt"

    cat > "${ROOTFS}/etc/modules-load.d/rpi-gpu.conf" << 'EOF'
vc4
v3d
EOF
    cat >> "${ROOTFS}/etc/initramfs-tools/modules" << 'EOF'
vc4
v3d
EOF
fi

# ---------- fstab ----------

if [ "$ARCH" = "amd64" ]; then
    install -m 644 /kiosk/files/fstab-amd64 "${ROOTFS}/etc/fstab"
elif [ "$ARCH" = "arm64" ]; then
    install -m 644 /kiosk/files/fstab-arm64 "${ROOTFS}/etc/fstab"
fi

# ---------- NetworkManager ----------

mkdir -p "${ROOTFS}/etc/netplan"
cat > "${ROOTFS}/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

mkdir -p "${ROOTFS}/etc/netplan"
cat > "${ROOTFS}/etc/netplan/00-default.yaml" << 'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 600 "${ROOTFS}/etc/netplan/00-default.yaml"

# ---------- Kiosk config (X11, no window manager) ----------

mkdir -p "${ROOTFS}/etc/kiosk"
install -m 755 /kiosk/files/xinitrc "${ROOTFS}/etc/kiosk/xinitrc"

install -m 755 /kiosk/files/kiosk-update "${ROOTFS}/usr/local/bin/kiosk-update"

# X started as a proper systemd service (not autologin+.bash_profile, which
# is tied to a getty/PAM login session's lifecycle and proved fragile -
# ties the X server's fate to VT/session handling it doesn't need to care
# about). Matches the pattern already proven in the pi-gen build
# (stage2/04-unitotem/files/start-xorg.service).
install -m 644 /kiosk/files/start-xorg.service \
    "${ROOTFS}/etc/systemd/system/start-xorg.service"

# ---------- OverlayFS initramfs hook ----------

install -m 755 /kiosk/files/overlayfs-hook.sh \
    "${ROOTFS}/etc/initramfs-tools/scripts/init-bottom/setup-overlays"
echo "overlay" >> "${ROOTFS}/etc/initramfs-tools/modules"
echo "FRAMEBUFFER=y" >> "${ROOTFS}/etc/initramfs-tools/initramfs.conf"

# ---------- System tuning ----------

cat >> "${ROOTFS}/etc/sysctl.conf" << 'EOF'
vm.dirty_writeback_centisecs = 3000
vm.dirty_expire_centisecs    = 3000
vm.dirty_ratio               = 5
vm.dirty_background_ratio    = 2
EOF

mkdir -p "${ROOTFS}/etc/systemd/journald.conf.d"
install -m 644 /kiosk/files/journald.conf \
    "${ROOTFS}/etc/systemd/journald.conf.d/kiosk.conf"

install -m 644 /kiosk/files/scheduler.rules \
    "${ROOTFS}/etc/udev/rules.d/60-scheduler.rules"

echo 'FSCKFIX=yes' >> "${ROOTFS}/etc/default/rcS"

# ---------- Firewall ----------

install -m 644 /kiosk/files/iptables-firewall.service \
    "${ROOTFS}/etc/systemd/system/iptables-firewall.service"
install -m 750 /kiosk/files/iptables-firewall.sh \
    "${ROOTFS}/sbin/iptables-firewall.sh"

install -m 644 /kiosk/files/kiosk-update-mode.service \
    "${ROOTFS}/etc/systemd/system/kiosk-update-mode.service"

# ---------- PipeWire user services ----------

mkdir -p "${ROOTFS}/root/.config/systemd/user/default.target.wants"
for svc in pipewire pipewire-pulse wireplumber; do
    ln -sf "/usr/lib/systemd/user/${svc}.service" \
        "${ROOTFS}/root/.config/systemd/user/default.target.wants/${svc}.service"
done

# ---------- Enable services ----------

chroot "${ROOTFS}" systemctl enable \
    systemd-timesyncd \
    NetworkManager \
    dbus \
    ssh \
    iptables-firewall \
    kiosk-update-mode \
    start-xorg

# ---------- Regenerate initramfs ----------

chroot "${ROOTFS}" update-initramfs -u -k all

# ---------- Cleanup ----------

if [ "$ARCH" = "arm64" ]; then
    rm -f "${ROOTFS}/usr/bin/qemu-aarch64-static"
fi

umount_chroot

echo "Saving stage 2 tarball..."
tar -C "${ROOTFS}" -czf "${WORK_DIR}/stage2.tar.gz" .

echo "=== Stage 2 complete ==="

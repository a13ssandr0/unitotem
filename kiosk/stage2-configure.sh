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

# ---------- Plymouth ----------
# No theme is installed/pinned here: the unitotem-manager package installs
# and selects the real "unitotem" theme (via update-alternatives AND
# plymouth-set-default-theme, since plymouthd.conf's Theme= key takes
# priority over the default.plymouth alternative - see
# src/main.c:load_settings()/show_default_splash() upstream) when it's
# installed on top of this image. Pinning a placeholder theme here would
# leave plymouthd.conf's Theme= key pointing at it, which the manager's
# update-alternatives call alone cannot override.

mkdir -p "${ROOTFS}/etc/plymouth"
install -m 644 /kiosk/files/plymouthd.conf "${ROOTFS}/etc/plymouth/plymouthd.conf"

# ---------- Bootloader configuration ----------

if [ "$ARCH" = "amd64" ]; then
    install -m 644 /kiosk/files/grub-default "${ROOTFS}/etc/default/grub"
    install -m 755 /kiosk/files/grub-ota-entry "${ROOTFS}/etc/grub.d/45_unitotem_ota"
fi

if [ "$ARCH" = "arm64" ]; then
    mkdir -p "${ROOTFS}/boot/firmware"
    install -m 644 /kiosk/files/config.txt "${ROOTFS}/boot/firmware/config.txt"
    # console=ttyS1 - NOT serial0, and NOT ttyS0 either. Both of those were
    # tried on real hardware and produced total silence on a known-good FT232.
    #
    # The serial console on the GPIO14/15 header pins is the mini-UART
    # (serial@7e215040, brcm,bcm2835-aux-uart). Two separate things decide what
    # to call it, and the Debian DTBs we ship differ from Raspberry Pi's own on
    # both counts:
    #  1. serial0/serial1 aliases are SWAPPED. Raspberry Pi's DTBs map
    #     serial0=&uart1 (mini-UART, header pins); mainline/Debian's
    #     bcm283x.dtsi maps serial0=&uart0 (PL011), and on a Pi 4 the PL011 is
    #     pinmuxed to GPIO30/32 for Bluetooth (it even carries a bluetooth child
    #     node). So console=serial0 sends every byte out the Bluetooth UART.
    #  2. The 8250 driver takes its tty INDEX from the DT serial alias, so with
    #     the mini-UART aliased as serial1 it enumerates as ttyS1 - ttyS0 does
    #     not exist at all. Verified by decompiling the very dtb on the card:
    #     serial1 = /soc/serial@7e215040, status okay, pinctrl uart1_gpio14
    #     (brcm,pins = <14 15>), and chosen/stdout-path = "serial1:115200n8".
    # Debian's own Raspberry Pi images use console=ttyS1,115200 for this reason.
    #
    # Needs enable_uart=1 in config.txt (the mini-UART derives its baud from the
    # VPU core clock; enable_uart=1 is what pins that clock). Note dtoverlay=
    # /dtparam= cannot help here: the Debian dtbs are built without -@, so they
    # carry no __symbols__/__overrides__ and no overlay can ever apply.
    # Revisit all of this if we ever switch to linux-image-rpi-v8, which brings
    # Raspberry Pi's own dtbs and therefore the other alias convention.
    echo "console=tty1 console=ttyS1,115200 root=LABEL=ROOT rootfstype=ext4 rootwait ro quiet splash loglevel=3 rd.systemd.show_status=false plymouth.ignore-serial-consoles" \
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

# ---------- OTA: real system's own initramfs entry points ----------
# ota-engine.sh and the unitotem-ota hook itself are already present (came
# in via stage1.tar.gz, kiosk/stage1-packages.sh) - only the real-system-
# specific dispatcher/verify wrappers and userspace-side pieces are added
# here. See the OTA redesign plan's "fallback: come lo si raggiunge" section
# for why the real system's initramfs needs to be OTA-capable too, not just
# the resident recovery image.

mkdir -p "${ROOTFS}/etc/initramfs-tools/scripts/init-premount"
install -m 755 /kiosk/files/ota-init-premount \
    "${ROOTFS}/etc/initramfs-tools/scripts/init-premount/zz-unitotem-ota"

mkdir -p "${ROOTFS}/etc/initramfs-tools/scripts/local-bottom"
install -m 755 /kiosk/files/ota-local-bottom-verify \
    "${ROOTFS}/etc/initramfs-tools/scripts/local-bottom/zz-unitotem-verify"

install -m 755 /kiosk/files/unitotem-ota-arm "${ROOTFS}/usr/sbin/unitotem-ota-arm"
install -m 755 /kiosk/files/unitotem-boot-ok "${ROOTFS}/usr/sbin/unitotem-boot-ok"
install -m 644 /kiosk/files/unitotem-boot-ok.service \
    "${ROOTFS}/etc/systemd/system/unitotem-boot-ok.service"

mkdir -p "${ROOTFS}/etc/unitotem"
install -m 644 /kiosk/files/ota-preserve.list "${ROOTFS}/etc/unitotem/ota-preserve.list"

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
    start-xorg \
    unitotem-boot-ok

# ---------- Regenerate initramfs ----------

chroot "${ROOTFS}" update-initramfs -u -k all

# ---------- arm64: populate FIRMWARE with the real system's boot files ----------
# Now that stage1 installs the real linux-image-rpi-v8 (not generic Debian
# linux-image-arm64), raspi-firmware's own kernel/initramfs postinst hooks
# (z50-raspi-firmware, which this project no longer needs to work around -
# see PLAN.md's arm64 follow-up) *should* already have copied
# kernel8.img/initramfs8/the dtbs during stage1's apt-get install. This
# manual copy stays anyway as a defensive safety net: linux-image-rpi-v8 and
# raspi-firmware are installed in the same apt-get transaction with no
# explicit Depends between them, so dpkg's configure order across the two
# isn't guaranteed - if the kernel's postinst happens to run before
# raspi-firmware's hook file exists, this catches it. Idempotent either way,
# and kiosk/stage3-image.sh's boot-ability assertions catch it immediately
# if it ever regresses.
if [ "$ARCH" = "arm64" ]; then
    KVER=$(cd "${ROOTFS}/lib/modules" && ls -1 | head -1)
    [ -n "${KVER}" ] || { echo "No kernel found under ${ROOTFS}/lib/modules" >&2; exit 1; }
    cp "${ROOTFS}/boot/vmlinuz-${KVER}"    "${ROOTFS}/boot/firmware/kernel8.img"
    cp "${ROOTFS}/boot/initrd.img-${KVER}" "${ROOTFS}/boot/firmware/initramfs8"
    cp "${ROOTFS}/usr/lib/linux-image-${KVER}"/broadcom/bcm27*.dtb "${ROOTFS}/boot/firmware/"
fi

# ---------- Cleanup ----------

if [ "$ARCH" = "arm64" ]; then
    rm -f "${ROOTFS}/usr/bin/qemu-aarch64-static"
fi

umount_chroot

echo "Saving stage 2 tarball..."
tar -C "${ROOTFS}" -czf "${WORK_DIR}/stage2.tar.gz" .

echo "=== Stage 2 complete ==="

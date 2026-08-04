#!/bin/bash
# Common functions and defaults for kiosk build stages

ARCH="${ARCH:-amd64}"
RELEASE="${RELEASE:-bookworm}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
WORK_DIR="/work/${ARCH}"
# Overridable because /tmp is only a sane place to build under Docker. On the
# real Pi (build nativa, see build-kiosk.sh) /tmp is a hardened tmpfs and
# stage0 died there immediately: debootstrap refuses a target mounted nodev
# ("Cannot install into target '/tmp/rootfs' mounted with noexec or nodev"),
# and at 256 MB it could not have held a multi-GB rootfs anyway. The native
# path points this at the build tree on DATA instead.
ROOTFS="${ROOTFS:-/tmp/rootfs}"

KIOSK_HOSTNAME="${KIOSK_HOSTNAME:-unitotem}"
ROOT_PASSWORD="${ROOT_PASSWORD:-unitotem}"
KIOSK_LOCALE="${KIOSK_LOCALE:-it_IT.UTF-8}"
KIOSK_TIMEZONE="${KIOSK_TIMEZONE:-Europe/Rome}"

IMAGE_SIZE="${IMAGE_SIZE:-11G}"
EFI_SIZE="${EFI_SIZE:-1G}"
BOOT_SIZE="${BOOT_SIZE:-1G}"
ROOT_SIZE="${ROOT_SIZE:-8G}"
FIRMWARE_SIZE="${FIRMWARE_SIZE:-1G}"

mount_chroot() {
    mount -t proc    proc          "${ROOTFS}/proc"     2>/dev/null || true
    mount -t sysfs   sysfs         "${ROOTFS}/sys"      2>/dev/null || true
    mount --bind     /dev          "${ROOTFS}/dev"      2>/dev/null || true
    mount --bind     /dev/pts      "${ROOTFS}/dev/pts"  2>/dev/null || true
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"
}

umount_chroot() {
    umount -lf "${ROOTFS}/dev/pts" 2>/dev/null || true
    umount -lf "${ROOTFS}/dev"     2>/dev/null || true
    umount -lf "${ROOTFS}/proc"    2>/dev/null || true
    umount -lf "${ROOTFS}/sys"     2>/dev/null || true
}

install_policy_rc() {
    cat > "${ROOTFS}/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
    chmod +x "${ROOTFS}/usr/sbin/policy-rc.d"
}

remove_policy_rc() {
    rm -f "${ROOTFS}/usr/sbin/policy-rc.d"
}

ensure_qemu() {
    if [ "$ARCH" = "arm64" ] && [ ! -f "${ROOTFS}/usr/bin/qemu-aarch64-static" ]; then
        cp /usr/bin/qemu-aarch64-static "${ROOTFS}/usr/bin/"
    fi
}

cleanup() {
    umount_chroot
    remove_policy_rc
}

trap cleanup EXIT INT TERM

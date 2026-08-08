#!/bin/bash
# Common functions and defaults for kiosk build stages

ARCH="${ARCH:-amd64}"
# Per-architecture on purpose, and asymmetric for a concrete reason rather
# than tidiness. amd64 moved to trixie because bookworm could not drive recent
# GPUs: kernel 6.1 hides Intel ARC behind i915.force_probe and Mesa 22.3 barely
# handles it, so that image had been assembled out of bookworm-backports.
# trixie ships all of it from stable - and newer (NVIDIA 550 rather than 535,
# Intel media 25.2 rather than 23.1) - which removes the backports scaffolding
# entirely.
#
# arm64 stays on bookworm and gains almost nothing from moving: the Raspberry
# Pi archive already ships a 6.12 kernel there, so the problem that forced
# amd64's hand never applied. The open risk is unitotem-manager's Python
# environment, which runs on 3.11 today and would meet 3.13 on trixie; keeping
# the Pi on bookworm keeps one known-working reference device while that is
# settled in the manager's own project.
if [ -z "${RELEASE:-}" ]; then
    case "$ARCH" in
        amd64) RELEASE=trixie ;;
        *)     RELEASE=bookworm ;;
    esac
fi
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
WORK_DIR="/work/${ARCH}"
# Overridable because /tmp is only a sane place to build under Docker. On the
# real Pi (build nativa, see build-kiosk.sh) /tmp is a hardened tmpfs and
# stage0 died there immediately: debootstrap refuses a target mounted nodev
# ("Cannot install into target '/tmp/rootfs' mounted with noexec or nodev"),
# and at 256 MB it could not have held a multi-GB rootfs anyway. The native
# path points this at the build tree on DATA instead.
ROOTFS="${ROOTFS:-/tmp/rootfs}"
# Where stage3 mounts the image it is assembling. Overridable for the same
# reason as ROOTFS, and it bit in the same way: /mnt is free inside the build
# container, but on a real UniTotem it is where DATA lives - so mounting the
# image there hid /mnt/data, and with it the build tree, mid-stage3. rsync
# then failed with "No such file or directory" on a rootfs that was still
# perfectly present, just no longer reachable.
IMG_MNT="${IMG_MNT:-/mnt}"

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

#!/bin/bash
# Common functions and defaults for kiosk build stages

ARCH="${ARCH:-amd64}"
# Both architectures on trixie now. amd64 moved first because bookworm could
# not drive recent GPUs at all: kernel 6.1 hides Intel ARC behind
# i915.force_probe and Mesa 22.3 barely handles it, so that image had been
# assembled out of bookworm-backports before this. arm64 was believed blocked
# on trixie - the Raspberry Pi archive's raspberrypi.gpg.key is a fixed,
# unmaintained artifact still self-signed with SHA1, which trixie's OpenPGP
# policy (SHA1 refused since 2026-02-01) rejects outright. That was true of
# the URL, not of Raspberry Pi's own current release: pi-gen itself trusts the
# packaged raspberrypi-archive-keyring rather than that URL (see this repo's
# vendored copy, stage0/00-configure-apt), and the copy published for trixie
# re-signs the same key with SHA512 - confirmed by downloading and inspecting
# it, not assumed. kiosk/stage1-packages.sh now fetches that packaged keyring
# instead of the stale URL.
#
# unitotem-manager's Python environment (3.11 today, 3.13 on trixie) is the
# one thing this does not verify - the package installs, but nothing has
# booted this image and run the manager under it yet.
RELEASE="${RELEASE:-trixie}"
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

# A/B layout (AB-DESIGN.md): two ROOT slots instead of one. Off by default until the
# whole boot/update chain is proven on hardware; the single-ROOT layout stays the
# supported one meanwhile. With A/B the image holds slot A only populated - slot B
# is written by the first update - but both partitions exist so DATA never moves again.
AB_LAYOUT="${AB_LAYOUT:-0}"
if [ "$AB_LAYOUT" = 1 ]; then
    ROOT_LABEL=ROOT_A
    IMAGE_SIZE="${IMAGE_SIZE:-14G}"
    ROOT_SLOT_SIZE="${ROOT_SLOT_SIZE:-5G}"
else
    ROOT_LABEL=ROOT
    IMAGE_SIZE="${IMAGE_SIZE:-11G}"
fi
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

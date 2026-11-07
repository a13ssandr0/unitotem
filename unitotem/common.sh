#!/bin/bash
# Common functions and defaults for kiosk build stages

ARCH="${ARCH:-amd64}"
# Both architectures build on trixie. The Raspberry Pi archive key is fetched
# from the packaged raspberrypi-archive-keyring (see stage1-packages.sh), because
# the legacy raspberrypi.gpg.key URL is SHA1-signed and refused by trixie's policy.
RELEASE="${RELEASE:-trixie}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"
WORK_DIR="/work/${ARCH}"
# Overridable: on the native Pi build /tmp is a small nodev tmpfs, which
# debootstrap refuses; the native path points this at the build tree on DATA.
ROOTFS="${ROOTFS:-/tmp/rootfs}"
# Where stage3 mounts the image it assembles. Overridable because on a real
# UniTotem /mnt holds DATA and mounting the image there would hide the build tree.
IMG_MNT="${IMG_MNT:-/mnt}"

UNITOTEM_HOSTNAME="${UNITOTEM_HOSTNAME:-unitotem}"
UNITOTEM_LOCALE="${UNITOTEM_LOCALE:-en_US.UTF-8}"
UNITOTEM_TIMEZONE="${UNITOTEM_TIMEZONE:-UTC}"

# A/B layout (docs/system/ab-updates.md): two ROOT slots. The image holds slot A populated;
# slot B is written by the first update, but both partitions exist so DATA never moves.
AB_LAYOUT="${AB_LAYOUT:-1}"
if [ "$AB_LAYOUT" = 1 ]; then
    ROOT_LABEL=ROOT_A
    IMAGE_SIZE="${IMAGE_SIZE:-14G}"
    ROOT_SLOT_SIZE="${ROOT_SLOT_SIZE:-5G}"
else
    ROOT_LABEL=ROOT
    IMAGE_SIZE="${IMAGE_SIZE:-11G}"
fi
EFI_SIZE="${EFI_SIZE:-512M}"
BOOT_SIZE="${BOOT_SIZE:-1G}"
ROOT_SIZE="${ROOT_SIZE:-8G}"
FIRMWARE_SIZE="${FIRMWARE_SIZE:-512M}"

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


# apt_install ARGS... : `apt-get install -y ARGS` inside the chroot, with the download step done first by aria2c
# (many files in flight at once). apt alone fetches one file at a time per host, so with ~800 small packages the
# per-request latency, not the link, sets the pace. Everything is verified twice: aria2 checks the SHA256 apt
# printed, and apt re-checks the archive it finds in the cache. Falls back to plain apt when aria2c is missing
# (the native Raspberry build host) or fails.
apt_install() {
    local uris
    uris=$(chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --print-uris "$@" 2>/dev/null \
           | grep "^'" || true)
    if [ -n "$uris" ] && command -v aria2c >/dev/null 2>&1; then
        local list; list=$(mktemp)
        # apt prints the hash as "SHA256:xxxx" (or SHA512/SHA1/MD5Sum for repositories without SHA256); aria2 wants
        # "sha-256=xxxx" etc. An unknown type is skipped rather than passed through - aria2 aborts the whole batch on it.
        printf '%s\n' "$uris" | awk '{u=$1; gsub(/\x27/,"",u); split($4, hh, ":"); t=hh[1]; h=hh[2];
            m["SHA256"]="sha-256"; m["SHA512"]="sha-512"; m["SHA1"]="sha-1"; m["MD5Sum"]="md5";
            print u; print "  out=" $2; if (h != "" && (t in m)) print "  checksum=" m[t] "=" h}' > "$list"
        mkdir -p "${ROOTFS}/var/cache/apt/archives"
        aria2c -q -i "$list" -d "${ROOTFS}/var/cache/apt/archives" -j 16 -x 4 -s 4 --file-allocation=none \
               --allow-overwrite=true --auto-file-renaming=false --retry-wait=3 --max-tries=5 \
            || echo "aria2c failed: apt will download by itself" >&2
        rm -f "$list"
    fi
    chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

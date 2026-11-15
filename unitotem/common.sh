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
export ROOTFS
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

# NATIVE_BUILD=1 (arm64 on an amd64 builder, docs/system/build.md "Native arm64 build"): packages are unpacked and configured by the
# host dpkg/apt with --root and --force-script-chrootless; no chroot, no binfmt. The few target programs a maintainer script
# calls by name are run one by one by unitotem/native/nb-shim (qemu-user inside a chroot of the target tree).
NATIVE_BUILD="${NATIVE_BUILD:-0}"
NB_DIR="${NB_DIR:-/tmp/nb}"
[ "$ARCH" = arm64 ] || NATIVE_BUILD=0

# nb_setup: shim directory first in PATH, apt configuration of the target, qemu binary in the tree (removed by nb_teardown).
nb_setup() {
    [ "$NATIVE_BUILD" = 1 ] || return 0
    mkdir -p "$NB_DIR/shims" "${ROOTFS}/usr/bin"
    [ -e "$NB_DIR/start-marker" ] || touch "$NB_DIR/start-marker"
    local n
    while read -r n; do
        case "$n" in ''|'#'*) continue ;; esac
        ln -sf /unitotem/native/nb-shim "$NB_DIR/shims/$n"
    done < /unitotem/native/shims.list
    export NB_ROOT="${ROOTFS}" PATH="$NB_DIR/shims:$PATH"
    cp /usr/bin/qemu-aarch64-static "${ROOTFS}/usr/bin/qemu-aarch64-static"
    mkdir -p "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/dev"
    mountpoint -q "${ROOTFS}/proc" || mount -t proc proc "${ROOTFS}/proc"
    mountpoint -q "${ROOTFS}/sys" || mount -t sysfs sysfs "${ROOTFS}/sys"
    mountpoint -q "${ROOTFS}/dev" || mount --bind /dev "${ROOTFS}/dev"
    # services are never started: policy-rc.d is read from the host side by invoke-rc.d
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
    cat > "$NB_DIR/apt.conf" << EOF_APT
APT::Architecture "arm64";
APT::Architectures "arm64";
APT::Sandbox::User "root";
Dir "${ROOTFS}";
Dir::State::Status "${ROOTFS}/var/lib/dpkg/status";
Dir::Etc::Trusted "${ROOTFS}/etc/apt/trusted.gpg";
Dir::Etc::TrustedParts "${ROOTFS}/etc/apt/trusted.gpg.d";
DPkg::Chroot-Directory "";
DPkg::Pre-Install-Pkgs "";
Dpkg::Use-Pty "false";
DPkg::Path "${NB_DIR}/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
pkgCacheGen::ForceEssential ",";
DPkg::Options { "--root=${ROOTFS}"; "--force-script-chrootless"; "--force-unsafe-io"; };
EOF_APT
}

# nb_host_touched: files of the builder's own root changed since nb_setup: a maintainer script that is not DPKG_ROOT aware
# wrote there instead of the target tree (listed in the log; the target then lacks that effect)
nb_host_touched() {
    [ "$NATIVE_BUILD" = 1 ] || return 0
    echo ">>> files of the builder root touched by maintainer scripts:"
    find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /tmp -o -path /work -o -path /aptcache -o -path /var/cache/apt -o -path /var/lib/apt -o -path /root \) -prune \
        -o -newer "$NB_DIR/start-marker" -not -type d -print 2>/dev/null | head -1000 | sed 's/^/NB-HOST-TOUCHED /' || true
}

nb_teardown() {
    [ "$NATIVE_BUILD" = 1 ] || return 0
    umount -lf "${ROOTFS}/dev" "${ROOTFS}/sys" "${ROOTFS}/proc" 2>/dev/null || true
    rm -f "${ROOTFS}/usr/bin/qemu-aarch64-static" /usr/sbin/policy-rc.d
}

# rootfs_apt ARGS: apt-get ARGS against the target tree. rootfs_dpkg, rootfs_dpkg_query likewise.
rootfs_apt() {
    if [ "$NATIVE_BUILD" = 1 ]; then
        # transactions (install, upgrade, purge) are replayed by nb-install; queries, update and clean go to apt directly
        local a act="" plain=0
        for a in "$@"; do
            case "$a" in
            -s|--simulate|--print-uris|--download-only) plain=1 ;;
            install|dist-upgrade|upgrade|purge|remove) [ -n "$act" ] || act="$a" ;;
            esac
        done
        if [ -n "$act" ] && [ "$plain" = 0 ]; then
            python3 -I /unitotem/native/nb-install "${ROOTFS}" "$NB_DIR/apt.conf" /unitotem/native/overrides "${ROOTFS}/tmp/extra-debs" "$@"
        else
            env DEBIAN_FRONTEND=noninteractive APT_CONFIG="$NB_DIR/apt.conf" apt-get "$@"
        fi
    else
        chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get "$@"
    fi
}
# nb_kernel_post: what the kernel hooks do for each kernel (/etc/kernel/postinst.d/z50-raspi-firmware): device trees, overlays
# and the kernel image into /boot/firmware.
nb_kernel_post() {
    [ "$NATIVE_BUILD" = 1 ] || return 0
    local k kver fw="${ROOTFS}/boot/firmware"
    mkdir -p "$fw/overlays"
    for k in "${ROOTFS}"/boot/vmlinuz-*-rpi-v8; do
        [ -e "$k" ] || continue
        kver=${k##*/vmlinuz-}
        cp -p "${ROOTFS}/usr/lib/linux-image-${kver}"/broadcom/bcm27*.dtb "$fw/"
        cp -p "${ROOTFS}/usr/lib/linux-image-${kver}"/overlays/*.dtb* "${ROOTFS}/usr/lib/linux-image-${kver}"/overlays/README "$fw/overlays/"
        cp -p "$k" "$fw/kernel8.img"
    done
}

rootfs_dpkg() {
    if [ "$NATIVE_BUILD" = 1 ]; then
        env DEBIAN_FRONTEND=noninteractive dpkg --root="${ROOTFS}" --force-script-chrootless --force-unsafe-io "$@"
    else
        chroot "${ROOTFS}" dpkg "$@"
    fi
}
rootfs_dpkg_query() {
    if [ "$NATIVE_BUILD" = 1 ]; then dpkg-query --admindir="${ROOTFS}/var/lib/dpkg" "$@"; else chroot "${ROOTFS}" dpkg-query "$@"; fi
}
rootfs_dpkg_statoverride() {
    if [ "$NATIVE_BUILD" = 1 ]; then dpkg-statoverride --root="${ROOTFS}" "$@"; else chroot "${ROOTFS}" dpkg-statoverride "$@"; fi
}

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
    nb_teardown
}

trap cleanup EXIT INT TERM


# apt_install ARGS... : `apt-get install -y ARGS` inside the chroot, with the download step done first by aria2c
# (many files in flight at once). apt alone fetches one file at a time per host, so with ~800 small packages the
# per-request latency, not the link, sets the pace. Everything is verified twice: aria2 checks the SHA256 apt
# printed, and apt re-checks the archive it finds in the cache. Falls back to plain apt when aria2c is missing
# (the native Raspberry build host) or fails.
apt_install() {
    local uris
    uris=$(rootfs_apt install -y --print-uris "$@" 2>/dev/null \
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
    rootfs_apt install -y "$@"
}

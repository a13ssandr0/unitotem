#!/bin/bash
set -euo pipefail
source /unitotem/common.sh

echo "=== Stage 0: Bootstrap (ARCH=${ARCH}) ==="

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}" "${WORK_DIR}"

if [ "$ARCH" = "amd64" ]; then
    debootstrap \
        --arch=amd64 \
        --include=systemd,systemd-sysv,udev,dbus \
        "$RELEASE" "${ROOTFS}" "$MIRROR"

elif [ "$ARCH" = "arm64" ] && [ "$NATIVE_BUILD" = 1 ]; then
    # Packages are unpacked and configured by the host dpkg (chrootless, no binfmt): see nb_setup in common.sh. The disposable
    # builder container is the "chroot" mmdebstrap asks for (ischroot), so its own root is the only thing a stray script can touch.
    mkdir -p "$NB_DIR/shims"
    printf '#!/bin/sh\nexit 0\n' > "$NB_DIR/shims/ischroot"; chmod +x "$NB_DIR/shims/ischroot"
    while read -r n; do
        case "$n" in ''|'#'*) continue ;; esac
        ln -sf /unitotem/native/nb-shim "$NB_DIR/shims/$n"
    done < /unitotem/native/shims.list
    rmdir "${ROOTFS}"
    NB_ROOT="${ROOTFS}" PATH="$NB_DIR/shims:$PATH" mmdebstrap --mode=chrootless --arch=arm64 --variant=important \
        --skip=check/qemu --aptopt="DPkg::Path \"$NB_DIR/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\";" --include=systemd,systemd-sysv,udev,dbus \
        --setup-hook='mkdir -p "$1/usr/bin" && cp /usr/bin/qemu-aarch64-static "$1/usr/bin/"' \
        --customize-hook='rm -f "$1/usr/bin/qemu-aarch64-static"' \
        "$RELEASE" "${ROOTFS}" "$MIRROR"
    # the base packages configured themselves with absolute builder paths: redo their file effects in the target tree
    NB_ROOT="${ROOTFS}" bash /unitotem/native/nb-stage0-configure "${ROOTFS}"
    # shadow passwords on (the passwd package's postinst does it with the builder's files)
    pwconv -R "${ROOTFS}"
    grpconv -R "${ROOTFS}"

elif [ "$ARCH" = "arm64" ]; then
    debootstrap \
        --arch=arm64 \
        --foreign \
        --include=systemd,systemd-sysv,udev,dbus \
        "$RELEASE" "${ROOTFS}" "$MIRROR"

    cp /usr/bin/qemu-aarch64-static "${ROOTFS}/usr/bin/"
    chroot "${ROOTFS}" /debootstrap/debootstrap --second-stage

else
    echo "Unsupported ARCH: $ARCH" >&2
    exit 1
fi

echo "Saving stage 0 tarball..."
tar -I pigz -C "${ROOTFS}" -cf "${WORK_DIR}/stage0.tar.gz" .

echo "=== Stage 0 complete ==="

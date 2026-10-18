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

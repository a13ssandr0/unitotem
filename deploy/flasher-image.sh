#!/bin/bash
# Runs INSIDE the kiosk-flasher-builder container (see Dockerfile.flasher and
# deploy/build-flasher.sh). Builds a standalone kernel+initrd pair whose only
# job is to run deploy/flasher/unitotem-flash - see that file for the actual
# flashing logic. Mirrors the kiosk/stageN.sh pattern (source common.sh,
# extract a tarball into a throwaway chroot, mount_chroot/umount_chroot) but
# starts from the *already built* work/$ARCH/stage2.tar.gz rather than
# re-bootstrapping, since the flasher must match the exact image it deploys.
set -euo pipefail
source /kiosk/common.sh

echo "=== Building flasher initrd (ARCH=${ARCH}) ==="

STAGE2="${WORK_DIR}/stage2.tar.gz"
[ -f "${STAGE2}" ] || {
    echo "Missing ${STAGE2} - run build-kiosk.sh (at least through stage 2) first." >&2
    exit 1
}

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}" "/deploy/${ARCH}"

echo "Extracting stage2..."
tar -C "${ROOTFS}" -xzf "${STAGE2}"

ensure_qemu
mount_chroot
install_policy_rc

# ---------- Build-only extra packages ----------
# None of this is installed into the shipped kiosk image (kiosk/stage1-packages.sh
# never lists these) - it only needs to exist long enough for mkinitramfs's
# copy_exec to pull the binaries into the flasher initrd.
chroot "${ROOTFS}" apt-get update
chroot "${ROOTFS}" apt-get install -y --no-install-recommends \
    gdisk parted netcat-traditional xz-utils zstd udhcpc

# ---------- Install the hook + init-premount script ----------

install -m 755 /kiosk/flasher/hook "${ROOTFS}/etc/initramfs-tools/hooks/unitotem-flash"
mkdir -p "${ROOTFS}/etc/initramfs-tools/scripts/init-premount"
install -m 755 /kiosk/flasher/unitotem-flash \
    "${ROOTFS}/etc/initramfs-tools/scripts/init-premount/unitotem-flash"

# The hook itself runs *inside* this chroot (mkinitramfs below is invoked
# via "chroot ${ROOTFS}"), so it can't reach /kiosk/flasher/* on the outer
# builder container - stage our custom udhcpc script inside the chroot
# first, at the path it'll also live at inside the initrd, so the hook can
# just copy_file it from there.
mkdir -p "${ROOTFS}/etc/udhcpc"
install -m 755 /kiosk/flasher/udhcpc-script "${ROOTFS}/etc/udhcpc/unitotem.script"

# Pull in every module family we might need on unknown target hardware
# (storage controllers, NICs) - this initrd is never used for normal boots,
# so the larger size doesn't matter.
sed -i 's/^MODULES=.*/MODULES=most/' "${ROOTFS}/etc/initramfs-tools/initramfs.conf"

# ---------- Build the initrd ----------

KVER=$(cd "${ROOTFS}/lib/modules" && ls -1 | head -1)
[ -n "${KVER}" ] || { echo "No kernel found under ${ROOTFS}/lib/modules" >&2; exit 1; }
echo "Kernel version: ${KVER}"

chroot "${ROOTFS}" mkinitramfs -o "/tmp/flash-initrd.img" "${KVER}"

cp "${ROOTFS}/tmp/flash-initrd.img" "/deploy/${ARCH}/flash-initrd-${ARCH}.img"
cp "${ROOTFS}/boot/vmlinuz-${KVER}"  "/deploy/${ARCH}/flash-vmlinuz-${ARCH}"

# ---------- Manifest ----------

KERNEL_SHA=$(sha256sum "/deploy/${ARCH}/flash-vmlinuz-${ARCH}"     | cut -d' ' -f1)
INITRD_SHA=$(sha256sum "/deploy/${ARCH}/flash-initrd-${ARCH}.img" | cut -d' ' -f1)

cat > "/deploy/${ARCH}/flash.manifest" << EOF
FLASH_ARCH=${ARCH}
FLASH_KERNEL_VERSION=${KVER}
FLASH_KERNEL_SHA256=${KERNEL_SHA}
FLASH_INITRD_SHA256=${INITRD_SHA}
FLASH_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ---------- Cleanup ----------

remove_policy_rc
umount_chroot

echo "=== Flasher build complete: /deploy/${ARCH}/flash-{vmlinuz,initrd-}${ARCH}.img ==="

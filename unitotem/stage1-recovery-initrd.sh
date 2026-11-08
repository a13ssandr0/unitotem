#!/bin/bash
# Builds the resident OTA fallback: a standalone kernel+initrd from work/$ARCH/stage1.tar.gz, before the kiosk
# configuration is added in stage2. It reuses unitotem/files/ota-hook, the same hook as the real system's
# `update-initramfs`, so the two cannot drift apart.
# Output: /deploy/$ARCH/recovery-vmlinuz-$ARCH, recovery-initrd-$ARCH.img, recovery.manifest (baked into every
# image's boot FAT partition by stage3-image.sh, and used by deploy/remote-deploy.sh).
set -euo pipefail
source /unitotem/common.sh

echo "=== Stage 1b: Recovery (fallback) kernel+initrd (ARCH=${ARCH}) ==="

STAGE1="${WORK_DIR}/stage1.tar.gz"
[ -f "${STAGE1}" ] || {
    echo "Missing ${STAGE1} - run unitotem/stage1-packages.sh first" >&2
    exit 1
}

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}" "/deploy/${ARCH}"

echo "Extracting stage 1..."
tar -I pigz -C "${ROOTFS}" -xf "${STAGE1}"

ensure_qemu
mount_chroot
install_policy_rc

# ---------- OTA hook + unconditional entry point ----------
# The hook is already in stage1.tar.gz. The init-premount script is not: the real system uses the conditional
# dispatcher (ota-init-premount, stage2), while this initrd always serves OTA. It is installed in this throwaway
# chroot so it never reaches stage1.tar.gz.
mkdir -p "${ROOTFS}/etc/initramfs-tools/scripts/init-premount"
install -m 755 /unitotem/files/ota-recovery-init-premount \
    "${ROOTFS}/etc/initramfs-tools/scripts/init-premount/zz-unitotem-ota"

# ---------- Module policy ----------
# MODULES=most is required: MODULES=dep probes the build chroot's root device
# ("mkinitramfs: failed to determine device for /"), which does not exist in a
# Docker chroot. It is also the right choice for hardware not known in advance.
grep -q '^MODULES=most' "${ROOTFS}/etc/initramfs-tools/initramfs.conf" \
    || sed -i 's/^MODULES=.*/MODULES=most/' "${ROOTFS}/etc/initramfs-tools/initramfs.conf"

KDIRS=$(find "${ROOTFS}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
KCOUNT=$(printf '%s' "${KDIRS}" | grep -c . || true)
[ "${KCOUNT}" = 1 ] || { echo "ERROR: expected exactly one kernel under ${ROOTFS}/lib/modules, found ${KCOUNT}" >&2; exit 1; }
KVER="${KDIRS}"
echo "Kernel version: ${KVER}"

chroot "${ROOTFS}" mkinitramfs -o "/tmp/recovery-initrd.img" "${KVER}"

cp "${ROOTFS}/tmp/recovery-initrd.img" "/deploy/${ARCH}/recovery-initrd-${ARCH}.img"
cp "${ROOTFS}/boot/vmlinuz-${KVER}"    "/deploy/${ARCH}/recovery-vmlinuz-${ARCH}"

VMLINUZ_SHA=$(sha256sum "/deploy/${ARCH}/recovery-vmlinuz-${ARCH}"    | cut -d' ' -f1)
INITRD_SHA=$(sha256sum  "/deploy/${ARCH}/recovery-initrd-${ARCH}.img" | cut -d' ' -f1)
PARTCLONE_VER=$(chroot "${ROOTFS}" partclone.restore -v 2>&1 | head -1 | awk '{print $2}')

cat > "/deploy/${ARCH}/recovery.manifest" << EOF
UNITOTEM_RECOVERY_ARCH=${ARCH}
UNITOTEM_RECOVERY_KERNEL_VERSION=${KVER}
UNITOTEM_RECOVERY_VMLINUZ_SHA256=${VMLINUZ_SHA}
UNITOTEM_RECOVERY_INITRD_SHA256=${INITRD_SHA}
UNITOTEM_RECOVERY_PARTCLONE_VERSION=${PARTCLONE_VER}
UNITOTEM_RECOVERY_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

remove_policy_rc
umount_chroot

echo "=== Stage 1b complete: /deploy/${ARCH}/recovery-{vmlinuz,initrd-}${ARCH}.img ==="

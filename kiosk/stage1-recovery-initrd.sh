#!/bin/bash
# Builds the resident OTA fallback: a standalone kernel+initrd pair, produced
# straight from work/$ARCH/stage1.tar.gz - before any kiosk-specific
# configuration (X11, plymouth, unitotem-manager, ...) is layered on in
# stage2. This is deliberate (see the OTA redesign plan, "Il fallback e' lo
# stage 1 della build"): stage1 already carries everything ota-engine.sh
# needs (kiosk/stage1-packages.sh's "OTA payload" block) and nothing it
# doesn't, so there is no separate flasher build to maintain and no risk of
# the fallback drifting out of sync with what the real system's own
# initramfs can do - kiosk/files/ota-hook (already installed into this same
# stage1 rootfs by kiosk/stage1-packages.sh) is the exact hook the real
# system's own `update-initramfs` uses too.
#
# Output: /deploy/$ARCH/recovery-vmlinuz-$ARCH, recovery-initrd-$ARCH.img,
# recovery.manifest - consumed by kiosk/stage3-image.sh (baked into every
# built image, boot FAT partition) and by deploy/remote-deploy.sh (pushed to
# an unprepared legacy target).
set -euo pipefail
source /kiosk/common.sh

echo "=== Stage 1b: Recovery (fallback) kernel+initrd (ARCH=${ARCH}) ==="

STAGE1="${WORK_DIR}/stage1.tar.gz"
[ -f "${STAGE1}" ] || {
    echo "Missing ${STAGE1} - run kiosk/stage1-packages.sh first" >&2
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
# The hook itself is already installed in stage1.tar.gz (kiosk/stage1-packages.sh,
# shared with the real system's initramfs); the init-premount script here is
# NOT - the real system needs the conditional dispatcher
# (kiosk/files/ota-init-premount, installed by stage2-configure.sh instead),
# while this recovery-only initrd should unconditionally serve OTA every
# single time it boots. Installed straight into this throwaway chroot so it
# never ends up in stage1.tar.gz.
mkdir -p "${ROOTFS}/etc/initramfs-tools/scripts/init-premount"
install -m 755 /kiosk/files/ota-recovery-init-premount \
    "${ROOTFS}/etc/initramfs-tools/scripts/init-premount/zz-unitotem-ota"

# ---------- Module policy ----------
# MODULES=most (initramfs-tools' most conservative setting, and
# initramfs-tools' own default) is required here, not just tolerated:
# MODULES=dep was tried and fails outright in this exact context
# ("mkinitramfs: failed to determine device for /") because it works by
# probing the BUILD chroot's own mounted root device to decide which
# modules are relevant - inside a Docker chroot there is no real block
# device backing "/", so that probe has nothing to find. MODULES=most
# doesn't need to know the target device at all, which is also exactly why
# it's the right choice for this initrd's actual job: booting on hardware
# that isn't known ahead of time.
#
# The real cause of the ~12 minute qemu-aarch64 build observed earlier
# (stuck copying irrelevant AMD GPU firmware, navi14_pfp_wks.bin, via
# mkinitramfs's firmware-file enumeration) was running mkinitramfs UNDER
# QEMU EMULATION, not the MODULES=most module set itself - see the OTA
# redesign plan's build-speed section. The fix is building natively (a real
# Pi over SSH, or any real arm64 host) instead of via Docker+binfmt for
# arm64, not trimming module coverage.
grep -q '^MODULES=most' "${ROOTFS}/etc/initramfs-tools/initramfs.conf" \
    || sed -i 's/^MODULES=.*/MODULES=most/' "${ROOTFS}/etc/initramfs-tools/initramfs.conf"

KVER=$(cd "${ROOTFS}/lib/modules" && ls -1 | head -1)
[ -n "${KVER}" ] || { echo "No kernel found under ${ROOTFS}/lib/modules" >&2; exit 1; }
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

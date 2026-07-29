#!/bin/bash
set -euo pipefail
source /kiosk/common.sh

echo "=== Stage 3: Disk Image Creation (ARCH=${ARCH}) ==="

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}" "/deploy/${ARCH}"

echo "Extracting stage 2..."
tar -C "${ROOTFS}" -xzf "${WORK_DIR}/stage2.tar.gz"

IMG_DATE="$(date +%Y-%m-%d)"
IMG_FILE="/deploy/${ARCH}/kiosk-${IMG_DATE}-${ARCH}.img"

echo "Creating image file: ${IMG_FILE} (${IMAGE_SIZE})"
truncate -s "${IMAGE_SIZE}" "${IMG_FILE}"

# ---------- Partition ----------

if [ "$ARCH" = "amd64" ]; then
    sgdisk -Z "${IMG_FILE}"
    sgdisk -n "1:0:+${EFI_SIZE}"  -t 1:ef00 -c 1:EFI  "${IMG_FILE}"
    sgdisk -n "2:0:+${BOOT_SIZE}" -t 2:8300 -c 2:BOOT "${IMG_FILE}"
    sgdisk -n "3:0:+${ROOT_SIZE}" -t 3:8300 -c 3:ROOT "${IMG_FILE}"
    sgdisk -n "4:0:0"             -t 4:8300 -c 4:DATA "${IMG_FILE}"
    # BIOS boot partition: sits in the (otherwise unused) gap between the
    # GPT header/table and partition 1's start at sector 2048, so it doesn't
    # shift any of the partitions above. Holds GRUB's core.img on legacy
    # BIOS targets - grub-install --target=i386-pc below embeds into it.
    # No filesystem, never mounted, harmless on UEFI-only machines.
    sgdisk -n "5:34:2047" -t 5:ef02 -c 5:BIOS "${IMG_FILE}"

elif [ "$ARCH" = "arm64" ]; then
    parted -s "${IMG_FILE}" mklabel gpt
    parted -s "${IMG_FILE}" mkpart FIRMWARE fat32  1M    512M
    parted -s "${IMG_FILE}" mkpart ROOT     ext4   512M  10756M
    parted -s "${IMG_FILE}" mkpart DATA     ext4   10756M 100%
fi

# ---------- Loop device ----------

LOOP=$(losetup --find --show --partscan "${IMG_FILE}")
echo "Loop device: ${LOOP}"

cleanup_loop() {
    umount -lf /mnt/mnt/data      2>/dev/null || true
    if [ "$ARCH" = "amd64" ]; then
        umount -lf /mnt/boot/efi  2>/dev/null || true
        umount -lf /mnt/boot      2>/dev/null || true
        umount -lf /mnt/dev       2>/dev/null || true
        umount -lf /mnt/proc      2>/dev/null || true
        umount -lf /mnt/sys       2>/dev/null || true
    elif [ "$ARCH" = "arm64" ]; then
        umount -lf /mnt/boot/firmware 2>/dev/null || true
    fi
    umount -lf /mnt               2>/dev/null || true
    losetup -d "${LOOP}"          2>/dev/null || true
}
trap cleanup_loop EXIT

# ---------- Format ----------

if [ "$ARCH" = "amd64" ]; then
    mkfs.fat -F32 -n EFI   "${LOOP}p1"
    mkfs.ext4 -F -L BOOT   "${LOOP}p2"
    mkfs.ext4 -F -L ROOT   "${LOOP}p3"
    mkfs.ext4 -F -L DATA -O ^has_journal "${LOOP}p4"

elif [ "$ARCH" = "arm64" ]; then
    mkfs.fat -F32 -n FIRMWARE "${LOOP}p1"
    mkfs.ext4 -F -L ROOT      "${LOOP}p2"
    mkfs.ext4 -F -L DATA -O ^has_journal "${LOOP}p3"
fi

# ---------- Mount & populate ----------

if [ "$ARCH" = "amd64" ]; then
    mount "${LOOP}p3" /mnt
    mkdir -p /mnt/{boot,mnt/data}
    mount "${LOOP}p2" /mnt/boot
    mkdir -p /mnt/boot/efi
    mount "${LOOP}p1" /mnt/boot/efi
    mount "${LOOP}p4" /mnt/mnt/data

elif [ "$ARCH" = "arm64" ]; then
    mount "${LOOP}p2" /mnt
    mkdir -p /mnt/{boot,mnt/data}
    mkdir -p /mnt/boot/firmware
    mount "${LOOP}p1" /mnt/boot/firmware
    mount "${LOOP}p3" /mnt/mnt/data
fi

echo "Copying rootfs..."
rsync -aHAXx --info=progress2 "${ROOTFS}/" /mnt/

# ---------- Install bootloader (amd64 only) ----------

if [ "$ARCH" = "amd64" ]; then
    mount --bind /dev  /mnt/dev
    mount --bind /proc /mnt/proc
    mount --bind /sys  /mnt/sys

    chroot /mnt grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --boot-directory=/boot \
        --bootloader-id=debian \
        --no-nvram \
        --removable

    # BIOS: embeds core.img into the ef02 partition carved out above and
    # writes the MBR boot code, so the same disk boots on both UEFI and
    # legacy BIOS firmware - matters for deploy/remote-deploy.sh, which
    # can't make a BIOS target bootable on its own if the image itself
    # never shipped BIOS support.
    chroot /mnt grub-install \
        --target=i386-pc \
        --boot-directory=/boot \
        "${LOOP}"

    chroot /mnt update-grub

    umount -lf /mnt/dev
    umount -lf /mnt/proc
    umount -lf /mnt/sys
fi

# ---------- Unmount ----------

sync

if [ "$ARCH" = "amd64" ]; then
    umount /mnt/mnt/data
    umount /mnt/boot/efi
    umount /mnt/boot
elif [ "$ARCH" = "arm64" ]; then
    umount /mnt/mnt/data
    umount /mnt/boot/firmware
fi
umount /mnt
losetup -d "${LOOP}"
trap - EXIT

# ---------- Compress ----------

echo "Compressing image..."
xz -v -T0 "${IMG_FILE}"

echo "=== Stage 3 complete: ${IMG_FILE}.xz ==="

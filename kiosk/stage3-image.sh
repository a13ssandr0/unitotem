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
# rm before truncate, not just truncate: `truncate -s SIZE` on a file that
# already exists at that size (any same-day rebuild - the filename is
# date-based) is a no-op, silently reusing whatever bytes the *previous*
# build left there. rsync -aHAXx below skips writing zero-byte runs it
# finds in the source (its own sparse-file optimization), trusting the
# destination is already zero at those offsets - on a genuinely fresh
# sparse file that's true; on a reused one it's not, and whatever stale
# bytes were there survive into the "new" image. Confirmed causing real,
# deterministic corruption (not flakiness - reproduced identically across
# repeated rebuilds of the same day's arm64 image, isolated to exactly the
# offsets where old and new content differed).
rm -f "${IMG_FILE}"
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
    # FIRMWARE_SIZE/ROOT_SIZE come da kiosk/common.sh, non piu' hardcoded:
    # FIRMWARE deve ospitare sia il kernel+initrd del fallback residente
    # (kiosk/stage1-recovery-initrd.sh) sia quelli del sistema reale, senza
    # che l'uno cancelli l'altro (vedi piano OTA, layout partizioni).
    size_to_mib() {
        local s="$1" num unit
        num="${s%[GgMm]}"
        unit="${s: -1}"
        case "$unit" in
            G|g) echo $((num * 1024)) ;;
            M|m) echo "$num" ;;
            *) echo "size_to_mib: unita' non riconosciuta in '$s'" >&2; exit 1 ;;
        esac
    }
    FW_START_MIB=1
    FW_END_MIB=$((FW_START_MIB + $(size_to_mib "$FIRMWARE_SIZE")))
    ROOT_END_MIB=$((FW_END_MIB + $(size_to_mib "$ROOT_SIZE")))

    parted -s "${IMG_FILE}" mklabel gpt
    parted -s "${IMG_FILE}" mkpart FIRMWARE fat32  "${FW_START_MIB}M"  "${FW_END_MIB}M"
    parted -s "${IMG_FILE}" mkpart ROOT     ext4   "${FW_END_MIB}M"   "${ROOT_END_MIB}M"
    parted -s "${IMG_FILE}" mkpart DATA     ext4   "${ROOT_END_MIB}M" 100%
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
# Without this, the boot-ability assertions below (arm64 especially - the
# amd64 branch happens to do enough intervening I/O via grub-install/
# update-grub to mask this) can read back stale/incomplete data for a large
# file just written (confirmed happening for real: a build's own on-disk
# initramfs8 read back without /init at check time, then read back complete
# and byte-identical to the known-good source on every later inspection -
# a flush timing race, not real corruption).
sync

# ---------- Recovery (fallback) kernel+initrd ----------
# Built by kiosk/stage1-recovery-initrd.sh straight from the stage1 rootfs,
# before any kiosk-specific configuration - must exist before stage3 runs.
# Copied onto the boot FAT partition at the FILE level (never with
# partclone), specifically so a later per-partition OTA restore of this same
# partition (deploy/make-parts.sh) can update the real system's kernel/dtb/
# initramfs entries without ever touching these files - see the OTA plan's
# partition layout section for why that separation is the whole point.
RECOVERY_VMLINUZ="/deploy/${ARCH}/recovery-vmlinuz-${ARCH}"
RECOVERY_INITRD="/deploy/${ARCH}/recovery-initrd-${ARCH}.img"
RECOVERY_MANIFEST="/deploy/${ARCH}/recovery.manifest"
for f in "$RECOVERY_VMLINUZ" "$RECOVERY_INITRD" "$RECOVERY_MANIFEST"; do
    [ -f "$f" ] || { echo "Missing $f - run kiosk/stage1-recovery-initrd.sh first" >&2; exit 1; }
done

if [ "$ARCH" = "amd64" ]; then
    mkdir -p /mnt/boot/efi/unitotem
    cp "$RECOVERY_VMLINUZ" /mnt/boot/efi/unitotem/recovery-vmlinuz
    cp "$RECOVERY_INITRD"  /mnt/boot/efi/unitotem/recovery-initrd.img
    {
        echo "$(sha256sum "$RECOVERY_VMLINUZ" | cut -d' ' -f1)  recovery-vmlinuz"
        echo "$(sha256sum "$RECOVERY_INITRD"  | cut -d' ' -f1)  recovery-initrd.img"
    } > /mnt/boot/efi/unitotem/recovery.sha256
elif [ "$ARCH" = "arm64" ]; then
    cp "$RECOVERY_VMLINUZ" /mnt/boot/firmware/recovery8.img
    cp "$RECOVERY_INITRD"  /mnt/boot/firmware/recovery-initrd.img
    {
        echo "$(sha256sum "$RECOVERY_VMLINUZ" | cut -d' ' -f1)  recovery8.img"
        echo "$(sha256sum "$RECOVERY_INITRD"  | cut -d' ' -f1)  recovery-initrd.img"
    } > /mnt/boot/firmware/recovery.sha256
fi

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

# ---------- Boot-ability assertions ----------
# The arm64 image previously shipped and only failed to boot on real
# hardware after the fact (missing kernel8.img/dtbs - see the OTA redesign
# plan's Context). These checks turn that class of bug into a build failure
# instead, while the relevant partitions are still mounted and cheap to
# inspect.
boot_assert_fail() { echo "BOOT-ABILITY CHECK FAILED: $*" >&2; exit 1; }

if [ "$ARCH" = "arm64" ]; then
    FWDIR=/mnt/boot/firmware

    [ -f "$FWDIR/kernel8.img" ] || boot_assert_fail "$FWDIR/kernel8.img assente"
    # Two valid formats here, not one: a raw uncompressed arm64 Image
    # ("ARMd" magic at offset 0x38 - what the generic Debian kernel this
    # project used to ship produced), or a gzip-compressed one (magic
    # 1f8b at offset 0) - the Pi firmware bootloader (start4.elf etc.)
    # decompresses gzip kernel8.img on the fly at boot, and that is
    # exactly the format linux-image-rpi-v8's own vmlinuz ships in
    # (confirmed directly against the real package, not assumed). Accept
    # either; only reject a file that is neither.
    magic_gzip=$(dd if="$FWDIR/kernel8.img" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$magic_gzip" != "1f8b" ]; then
        magic=$(dd if="$FWDIR/kernel8.img" bs=1 skip=56 count=4 2>/dev/null)
        [ "$magic" = "ARMd" ] \
            || boot_assert_fail "kernel8.img non e' ne' un Image arm64 grezzo valido (magic letto: '${magic}', atteso 'ARMd' a offset 0x38) ne' gzip-compresso (magic: '${magic_gzip}', atteso '1f8b')"
    fi

    dtb_count=$(find "$FWDIR" -maxdepth 1 -iname "bcm27*.dtb" | wc -l)
    [ "$dtb_count" -gt 0 ] || boot_assert_fail "nessun bcm27*.dtb su $FWDIR"
    for dtb in "$FWDIR"/bcm27*.dtb; do
        dtc -I dtb -O dts "$dtb" > /dev/null 2>&1 || boot_assert_fail "$dtb non e' un dtb valido (dtc non riesce a parsarlo)"
    done

    [ -s "$FWDIR/initramfs8" ] || boot_assert_fail "$FWDIR/initramfs8 assente o vuoto"
    # Decompress to a regular file first, then inspect that - not a live
    # `zcat | cpio -t | grep -q` pipe. Confirmed by hand that the pipe form
    # can report "no /init" on a file that is actually fine: pulling the
    # same freshly-written initramfs8 (87MB compressed / 257MB raw) back out
    # via an independent remount and inspecting it sequentially (decompress
    # to a file, then cpio -t on that file) found /init cleanly and listed
    # all 2602 entries, both times, repeatably - while the same bytes read
    # through the three-concurrent-process pipe form intermittently came up
    # empty. The data was never corrupt; only the concurrent-pipe read of it
    # was unreliable, so the check no longer uses one.
    zcat "$FWDIR/initramfs8" > /tmp/initramfs8-check.raw 2>/tmp/initramfs8-check.err \
        || boot_assert_fail "$FWDIR/initramfs8: zcat fallito ($(cat /tmp/initramfs8-check.err))"
    cpio -t < /tmp/initramfs8-check.raw > /tmp/initramfs8-check.list 2>/dev/null \
        || boot_assert_fail "$FWDIR/initramfs8: cpio -t fallito nel leggerlo"
    grep -qE "^init$|sbin/init$" /tmp/initramfs8-check.list \
        || boot_assert_fail "$FWDIR/initramfs8 non contiene /init"
    rm -f /tmp/initramfs8-check.raw /tmp/initramfs8-check.list /tmp/initramfs8-check.err

    grep -q "^kernel=" "$FWDIR/config.txt" || boot_assert_fail "config.txt: manca kernel="
    grep -q "^initramfs .* followkernel" "$FWDIR/config.txt" || boot_assert_fail "config.txt: manca 'initramfs ... followkernel'"
    # Nessun dtoverlay attivo deve puntare a un file assente in overlays/ - il
    # pacchetto kernel Debian generico non ne spedisce nessuno (vedi il
    # follow-up "passare a linux-image-rpi-v8" nella documentazione OTA).
    while read -r ov; do
        [ -f "$FWDIR/overlays/${ov}.dtbo" ] \
            || boot_assert_fail "config.txt referenzia dtoverlay=${ov} ma $FWDIR/overlays/${ov}.dtbo non esiste"
    done < <(awk -F= '/^dtoverlay=/{print $2}' "$FWDIR/config.txt")
fi

if [ "$ARCH" = "amd64" ]; then
    RECOVERY_VMLINUZ_INSTALLED=/mnt/boot/efi/unitotem/recovery-vmlinuz
    RECOVERY_INITRD_INSTALLED=/mnt/boot/efi/unitotem/recovery-initrd.img
else
    RECOVERY_VMLINUZ_INSTALLED=/mnt/boot/firmware/recovery8.img
    RECOVERY_INITRD_INSTALLED=/mnt/boot/firmware/recovery-initrd.img
fi
for pair in "$RECOVERY_VMLINUZ:$RECOVERY_VMLINUZ_INSTALLED" "$RECOVERY_INITRD:$RECOVERY_INITRD_INSTALLED"; do
    src="${pair%%:*}"; installed="${pair#*:}"
    [ -f "$installed" ] || boot_assert_fail "$installed assente dopo la copia"
    expect=$(sha256sum "$src" | cut -d' ' -f1)
    got=$(sha256sum "$installed" | cut -d' ' -f1)
    [ "$expect" = "$got" ] || boot_assert_fail "$installed: sha256 non corrisponde all'artefatto sorgente ($src)"
done

if [ "$ARCH" = "amd64" ]; then
    BOOTFS_FREE=$(df -B1 --output=avail /mnt/boot/efi | tail -1 | tr -d ' ')
else
    BOOTFS_FREE=$(df -B1 --output=avail /mnt/boot/firmware | tail -1 | tr -d ' ')
fi
[ "$BOOTFS_FREE" -ge $((64 * 1024 * 1024)) ] \
    || boot_assert_fail "meno di 64MiB liberi sulla partizione di boot dopo tutte le copie ($((BOOTFS_FREE / 1024 / 1024))MiB)"

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

# fsck after unmount, directly on the loop partitions - a mounted (even
# read-only-checked) filesystem doesn't give fsck a reliable view.
if [ "$ARCH" = "amd64" ]; then
    fsck.vfat -n "${LOOP}p1" || boot_assert_fail "fsck.vfat su EFI (${LOOP}p1) non pulito"
    fsck.ext4 -fn "${LOOP}p2" || boot_assert_fail "fsck.ext4 su BOOT (${LOOP}p2) non pulito"
    fsck.ext4 -fn "${LOOP}p3" || boot_assert_fail "fsck.ext4 su ROOT (${LOOP}p3) non pulito"
    fsck.ext4 -fn "${LOOP}p4" || boot_assert_fail "fsck.ext4 su DATA (${LOOP}p4) non pulito"
elif [ "$ARCH" = "arm64" ]; then
    fsck.vfat -n "${LOOP}p1" || boot_assert_fail "fsck.vfat su FIRMWARE (${LOOP}p1) non pulito"
    fsck.ext4 -fn "${LOOP}p2" || boot_assert_fail "fsck.ext4 su ROOT (${LOOP}p2) non pulito"
    fsck.ext4 -fn "${LOOP}p3" || boot_assert_fail "fsck.ext4 su DATA (${LOOP}p3) non pulito"
fi

losetup -d "${LOOP}"
trap - EXIT

# ---------- Optional: parts set from this same build ----------
# Off by default - deploy/make-parts.sh (decoupled from the kiosk build, see
# that script) is the primary path, precisely so the parts format can
# change without forcing a rebuild here. This exists only to make a parts
# set free when a build is happening anyway. Runs against the still-
# uncompressed ${IMG_FILE} (loop already detached above, so it re-attaches
# its own read-only loop rather than reusing ${LOOP} past its teardown).
if [ "${MAKE_PARTS:-0}" = 1 ]; then
    echo "Generating parts set (MAKE_PARTS=1)..."
    source /kiosk/deploy-parts-lib.sh
    PARTS_LOOP=$(losetup --find --show --partscan --read-only "${IMG_FILE}")
    trap "losetup -d '${PARTS_LOOP}' 2>/dev/null || true" EXIT
    make_parts "${PARTS_LOOP}" "/deploy/${ARCH}/kiosk-${IMG_DATE}-${ARCH}.parts" \
        "${ARCH}" "kiosk-${IMG_DATE}-${ARCH}" "${IMG_FILE}"
    losetup -d "${PARTS_LOOP}"
    trap - EXIT
fi

# ---------- Compress ----------

echo "Compressing image..."
rm -f "${IMG_FILE}.xz"   # a same-day rerun would otherwise make plain xz refuse to overwrite
xz -v -T0 "${IMG_FILE}"

echo "=== Stage 3 complete: ${IMG_FILE}.xz ==="

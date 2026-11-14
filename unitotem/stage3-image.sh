#!/bin/bash
set -euo pipefail
source /unitotem/common.sh

echo "=== Stage 3: Disk Image Creation (ARCH=${ARCH}) ==="

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}" "/deploy/${ARCH}"

echo "Extracting stage 2..."
tar -I pigz -C "${ROOTFS}" -xf "${WORK_DIR}/stage2.tar.gz"

IMG_DATE="$(date +%Y-%m-%d)"
IMG_FILE="/deploy/${ARCH}/unitotem-${IMG_DATE}-${ARCH}.img"

echo "Creating image file: ${IMG_FILE} (${IMAGE_SIZE})"
# rm before truncate: truncate on an existing file of the same size (a same-day rebuild) is a
# no-op, and rsync skips zero runs in the source, so stale bytes of the previous build would
# survive into the new image.
rm -f "${IMG_FILE}"
truncate -s "${IMAGE_SIZE}" "${IMG_FILE}"

# ---------- Partition ----------

# Partition numbers differ between layouts, so name them once and use the names below.
# A/B (AB_LAYOUT=1): amd64 EFI/ROOT_A/ROOT_B/DATA (no BOOT: GRUB lives on the ESP and each
# slot carries its own kernel), arm64 FIRMWARE/ROOT_A/ROOT_B/DATA.
if [ "$ARCH" = "amd64" ]; then
    if [ "$AB_LAYOUT" = 1 ]; then P_BOOTFS=1 P_ROOT=2 P_ROOTB=3 P_DATA=4 P_BOOT=
    else P_BOOTFS=1 P_BOOT=2 P_ROOT=3 P_ROOTB= P_DATA=4; fi
else
    if [ "$AB_LAYOUT" = 1 ]; then P_BOOTFS=1 P_BOOT= P_ROOT=2 P_ROOTB=3 P_DATA=4
    else P_BOOTFS=1 P_BOOT= P_ROOT=2 P_ROOTB= P_DATA=3; fi
fi

if [ "$ARCH" = "amd64" ]; then
    sgdisk -Z "${IMG_FILE}"
    sgdisk -n "1:0:+${EFI_SIZE}"  -t 1:ef00 -c 1:EFI  "${IMG_FILE}"
    if [ "$AB_LAYOUT" = 1 ]; then
        sgdisk -n "2:0:+${ROOT_SLOT_SIZE}" -t 2:8300 -c 2:ROOT_A "${IMG_FILE}"
        sgdisk -n "3:0:+${ROOT_SLOT_SIZE}" -t 3:8300 -c 3:ROOT_B "${IMG_FILE}"
    else
        sgdisk -n "2:0:+${BOOT_SIZE}" -t 2:8300 -c 2:BOOT "${IMG_FILE}"
        sgdisk -n "3:0:+${ROOT_SIZE}" -t 3:8300 -c 3:ROOT "${IMG_FILE}"
    fi
    sgdisk -n "4:0:0"             -t 4:8300 -c 4:DATA "${IMG_FILE}"
    # BIOS boot partition in the gap before partition 1 (sector 2048), so no other partition
    # shifts. Holds GRUB's core.img for legacy BIOS (grub-install --target=i386-pc below).
    sgdisk -n "5:34:2047" -t 5:ef02 -c 5:BIOS "${IMG_FILE}"

elif [ "$ARCH" = "arm64" ]; then
    # FIRMWARE must hold both the resident fallback's kernel+initrd and the real system's,
    # without either overwriting the other. Sizes come from unitotem/common.sh.
    size_to_mib() {
        local s="$1" num unit
        num="${s%[GgMm]}"
        unit="${s: -1}"
        case "$unit" in
            G|g) echo $((num * 1024)) ;;
            M|m) echo "$num" ;;
            *) echo "size_to_mib: unrecognized unit in '$s'" >&2; exit 1 ;;
        esac
    }
    FW_START_MIB=1
    FW_END_MIB=$((FW_START_MIB + $(size_to_mib "$FIRMWARE_SIZE")))
    parted -s "${IMG_FILE}" mklabel gpt
    parted -s "${IMG_FILE}" mkpart FIRMWARE fat32  "${FW_START_MIB}M"  "${FW_END_MIB}M"
    if [ "$AB_LAYOUT" = 1 ]; then
        SLOT_MIB=$(size_to_mib "$ROOT_SLOT_SIZE")
        A_END_MIB=$((FW_END_MIB + SLOT_MIB))
        B_END_MIB=$((A_END_MIB + SLOT_MIB))
        # MiB, not M: parted's bare "M" is 10^6 bytes, which misaligns every boundary.
        parted -s "${IMG_FILE}" mkpart ROOT_A ext4 "${FW_END_MIB}MiB" "${A_END_MIB}MiB"
        parted -s "${IMG_FILE}" mkpart ROOT_B ext4 "${A_END_MIB}MiB"  "${B_END_MIB}MiB"
        parted -s "${IMG_FILE}" mkpart DATA   ext4 "${B_END_MIB}MiB"  100%
    else
        ROOT_END_MIB=$((FW_END_MIB + $(size_to_mib "$ROOT_SIZE")))
        parted -s "${IMG_FILE}" mkpart ROOT ext4 "${FW_END_MIB}M"   "${ROOT_END_MIB}M"
        parted -s "${IMG_FILE}" mkpart DATA ext4 "${ROOT_END_MIB}M" 100%
    fi
fi

# ---------- Loop device ----------

LOOP=$(losetup --find --show --partscan "${IMG_FILE}")
echo "Loop device: ${LOOP}"

cleanup_loop() {
    umount -lf ${IMG_MNT}/mnt/data      2>/dev/null || true
    if [ "$ARCH" = "amd64" ]; then
        umount -lf ${IMG_MNT}/boot/efi  2>/dev/null || true
        umount -lf ${IMG_MNT}/boot      2>/dev/null || true
        umount -lf ${IMG_MNT}/dev       2>/dev/null || true
        umount -lf ${IMG_MNT}/proc      2>/dev/null || true
        umount -lf ${IMG_MNT}/sys       2>/dev/null || true
    elif [ "$ARCH" = "arm64" ]; then
        umount -lf ${IMG_MNT}/boot/firmware 2>/dev/null || true
    fi
    umount -lf ${IMG_MNT}               2>/dev/null || true
    losetup -d "${LOOP}"          2>/dev/null || true
}
trap cleanup_loop EXIT

# ---------- Format ----------

if [ "$ARCH" = "amd64" ]; then
    mkfs.fat -F32 -n EFI   "${LOOP}p${P_BOOTFS}"
    [ -z "$P_BOOT" ] || mkfs.ext4 -F -L BOOT "${LOOP}p${P_BOOT}"
elif [ "$ARCH" = "arm64" ]; then
    mkfs.fat -F32 -n FIRMWARE "${LOOP}p${P_BOOTFS}"
fi
mkfs.ext4 -F -L "${ROOT_LABEL}" "${LOOP}p${P_ROOT}"
# Slot B starts empty but formatted and labelled; the first update only writes into it.
[ -z "$P_ROOTB" ] || mkfs.ext4 -F -L ROOT_B "${LOOP}p${P_ROOTB}"
# DATA keeps its journal (data=ordered): without one a power cut left state files as NULs and a
# directory entry missing, with nothing to replay and no fsck at boot.
mkfs.ext4 -F -L DATA "${LOOP}p${P_DATA}"

boot_assert_fail() { echo "BOOT-ABILITY CHECK FAILED: $*" >&2; exit 1; }

# ---------- Mount & populate ----------

# IMG_MNT can be overridden, and mount fails on a missing mountpoint.
mkdir -p "${IMG_MNT}"

mount "${LOOP}p${P_ROOT}" ${IMG_MNT}
mkdir -p ${IMG_MNT}/{boot,mnt/data}
if [ "$ARCH" = "amd64" ]; then
    [ -z "$P_BOOT" ] || mount "${LOOP}p${P_BOOT}" ${IMG_MNT}/boot
    mkdir -p ${IMG_MNT}/boot/efi
    mount "${LOOP}p${P_BOOTFS}" ${IMG_MNT}/boot/efi
elif [ "$ARCH" = "arm64" ]; then
    mkdir -p ${IMG_MNT}/boot/firmware
    mount "${LOOP}p${P_BOOTFS}" ${IMG_MNT}/boot/firmware
fi
mount "${LOOP}p${P_DATA}" ${IMG_MNT}/mnt/data

echo "Copying rootfs..."
rsync -aHAXx --info=progress2 "${ROOTFS}/" ${IMG_MNT}/
# Flush before the boot-ability assertions below, which could otherwise read back
# incomplete data for a large file just written.
sync

# ---------- Recovery (fallback) kernel+initrd ----------
# Built by unitotem/stage1-recovery-initrd.sh from the stage1 rootfs; must exist before stage3 runs.
# Copied onto the boot FAT partition at the FILE level (never with partclone), so a later
# per-partition OTA restore of this partition (deploy/make-parts.sh) can update the real
# system's kernel/dtb/initramfs entries without touching these files.
RECOVERY_VMLINUZ="/deploy/${ARCH}/recovery-vmlinuz-${ARCH}"
RECOVERY_INITRD="/deploy/${ARCH}/recovery-initrd-${ARCH}.img"
RECOVERY_MANIFEST="/deploy/${ARCH}/recovery.manifest"
for f in "$RECOVERY_VMLINUZ" "$RECOVERY_INITRD" "$RECOVERY_MANIFEST"; do
    [ -f "$f" ] || { echo "Missing $f - run unitotem/stage1-recovery-initrd.sh first" >&2; exit 1; }
done

# Level of the set: the build date as 14 digits (2026-10-19T05:56:32Z -> 20261019055632).
RECOVERY_BUILD_DATE=$(sed -n 's/^UNITOTEM_RECOVERY_BUILD_DATE=//p' "$RECOVERY_MANIFEST")
RECOVERY_LEVEL=$(printf '%s' "$RECOVERY_BUILD_DATE" | tr -cd '0-9')
[[ "$RECOVERY_LEVEL" =~ ^[0-9]{14}$ ]] \
    || { echo "$RECOVERY_MANIFEST: UNITOTEM_RECOVERY_BUILD_DATE missing or not 14 digits ('$RECOVERY_BUILD_DATE')" >&2; exit 1; }

# Top-level dtbs (arm64): the fallback's device tree. The A/B block below copies them into the
# slot directories; the top-level originals stay for the fallback.
DTBS=()
if [ "$ARCH" = "arm64" ]; then
    mapfile -t DTBS < <(find "${IMG_MNT}/boot/firmware" -maxdepth 1 -type f -name '*.dtb' -printf '%f\n' | LC_ALL=C sort)
fi

# Boot FAT copy under unchanged names. recovery.sha256 starts with the level line.
if [ "$ARCH" = "amd64" ]; then
    FAT_DIR=${IMG_MNT}/boot/efi/unitotem
    FAT_VMLINUZ=recovery-vmlinuz
else
    FAT_DIR=${IMG_MNT}/boot/firmware
    FAT_VMLINUZ=recovery8.img
fi
mkdir -p "$FAT_DIR"
cp "$RECOVERY_VMLINUZ" "$FAT_DIR/$FAT_VMLINUZ"
cp "$RECOVERY_INITRD"  "$FAT_DIR/recovery-initrd.img"
VMLINUZ_SHA=$(sha256sum "$RECOVERY_VMLINUZ" | cut -d' ' -f1)
INITRD_SHA=$(sha256sum "$RECOVERY_INITRD"  | cut -d' ' -f1)
FAT_SUMS=("$VMLINUZ_SHA  $FAT_VMLINUZ" "$INITRD_SHA  recovery-initrd.img")
SET_SUMS=("$VMLINUZ_SHA  vmlinuz" "$INITRD_SHA  initrd.img")

# Image-owned set read by unitotem-update: vmlinuz, initrd.img, dtb/NAME (see docs/system/boot.md).
RECOVERY_SET=${IMG_MNT}/usr/share/unitotem/recovery
install -d -m 755 "$RECOVERY_SET"
install -m 644 "$RECOVERY_VMLINUZ" "$RECOVERY_SET/vmlinuz"
install -m 644 "$RECOVERY_INITRD"  "$RECOVERY_SET/initrd.img"
if [ "${#DTBS[@]}" -gt 0 ]; then
    install -d -m 755 "$RECOVERY_SET/dtb"
fi
for name in "${DTBS[@]}"; do
    install -m 644 "${IMG_MNT}/boot/firmware/$name" "$RECOVERY_SET/dtb/$name"
    sum=$(sha256sum "$RECOVERY_SET/dtb/$name" | cut -d' ' -f1)
    SET_SUMS+=("$sum  dtb/$name")
    FAT_SUMS+=("$sum  $name")
done

{
    echo "# unitotem-recovery-level: $RECOVERY_LEVEL"
    printf '%s\n' "${FAT_SUMS[@]}"
} > "$FAT_DIR/recovery.sha256"
{
    echo "# unitotem-recovery-level: $RECOVERY_LEVEL"
    printf '%s\n' "${SET_SUMS[@]}"
} > "$RECOVERY_SET/manifest"
chmod 644 "$RECOVERY_SET/manifest"

# ---------- A/B on arm64: kernel, initramfs, dtbs and cmdline go in a per-slot directory ----------
# `os_prefix=slota/` in config.txt makes the firmware read kernel, initramfs, dtbs, overlays and
# cmdline.txt from that subdirectory; the firmware proper (start*.elf, fixup*.dat, bootcode.bin)
# and config.txt stay at the top. Slot B's directory is written by the first update.
if [ "$ARCH" = "arm64" ] && [ "$AB_LAYOUT" = 1 ]; then
    FW=${IMG_MNT}/boot/firmware
    mkdir -p "$FW/slota"
    for f in kernel8.img initramfs8 cmdline.txt; do
        [ -e "$FW/$f" ] && mv "$FW/$f" "$FW/slota/$f"
    done
    # dtbs and overlays are COPIED, not moved: the resident fallback (config.txt without
    # os_prefix) loads its device tree from the top of the partition, and a kernel without a
    # dtb stops at the rainbow screen.
    cp -r "$FW/overlays" "$FW/slota/overlays" 2>/dev/null || true
    for f in "$FW"/*.dtb; do [ -e "$f" ] && cp "$f" "$FW/slota/"; done
    sed -i '0,/^\[all\]/s//[all]\nos_prefix=slota\//' "$FW/config.txt"
    grep -q '^os_prefix=slota/' "$FW/config.txt" || { echo "config.txt: os_prefix not inserted" >&2; exit 1; }
    # the fallback's device tree must stay where its config.txt (no os_prefix) looks for it
    [ -s "$FW/bcm2711-rpi-4-b.dtb" ] || { echo "BOOT-ABILITY: bcm2711-rpi-4-b.dtb missing at the top level: the fallback could not boot" >&2; exit 1; }
fi

# ---------- Install bootloader (amd64 only) ----------

if [ "$ARCH" = "amd64" ]; then
    mount --bind /dev  ${IMG_MNT}/dev
    mount --bind /proc ${IMG_MNT}/proc
    mount --bind /sys  ${IMG_MNT}/sys

    # A/B has no BOOT partition: GRUB's directory (grub.cfg, grubenv) lives on the ESP, the one
    # filesystem both slots share, so the default/trial selection survives a slot being rewritten.
    if [ "$AB_LAYOUT" = 1 ]; then GRUB_BOOTDIR=/boot/efi/unitotem-grub; else GRUB_BOOTDIR=/boot; fi
    mkdir -p "${IMG_MNT}${GRUB_BOOTDIR}"

    chroot ${IMG_MNT} grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --boot-directory="${GRUB_BOOTDIR}" \
        --bootloader-id=debian \
        --no-nvram \
        --no-uefi-secure-boot \
        --removable

    # BIOS: embeds core.img into the ef02 partition and writes the MBR boot code, so the same
    # disk boots on UEFI and legacy BIOS (remote-deploy.sh cannot make a BIOS target bootable
    # if the image has no BIOS support).
    chroot ${IMG_MNT} grub-install \
        --target=i386-pc \
        --boot-directory="${GRUB_BOOTDIR}" \
        "${LOOP}"

    # Secure Boot chain, active from the first boot: EFI/BOOT holds the Debian-signed shim as BOOTX64.EFI (the file every firmware
    # loads), MokManager, the Debian-signed GRUB and the stubs that hand over to the real configuration (grub.cfg + grubenv in
    # unitotem-grub/ on this partition). The signed GRUB has a fixed prefix and finds only grub.cfg stubs: EFI/BOOT and EFI/debian.
    # The chain boots with and without Secure Boot, so a machine is ready for Secure Boot with no step. No other .efi file is shipped.
    # (--no-uefi-secure-boot above keeps grub-install from placing a half chain: the plain GRUB it writes is replaced here.)
    if [ "$AB_LAYOUT" = 1 ]; then
        BTDIR=${IMG_MNT}/boot/efi/EFI/BOOT
        mkdir -p "$BTDIR" "${IMG_MNT}/boot/efi/EFI/debian"
        cp "${IMG_MNT}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$BTDIR/grubx64.efi"
        cp "${IMG_MNT}/usr/lib/shim/mmx64.efi.signed"                     "$BTDIR/mmx64.efi"
        cat > "$BTDIR/grub.cfg" << 'SBEOF'
# UniTotem Secure Boot stub: hands over to the real GRUB configuration on this ESP.
search --no-floppy --label --set=root EFI
set prefix=($root)/unitotem-grub/grub
configfile ($root)/unitotem-grub/grub/grub.cfg
SBEOF
        cp "$BTDIR/grub.cfg" "${IMG_MNT}/boot/efi/EFI/debian/grub.cfg"
        sync
        # shim last, through a temporary name: the firmware never sees a half chain
        cp "${IMG_MNT}/usr/lib/shim/shimx64.efi.signed" "$BTDIR/BOOTX64.EFI.new" && mv -f "$BTDIR/BOOTX64.EFI.new" "$BTDIR/BOOTX64.EFI"
        for f in BOOTX64.EFI mmx64.efi grubx64.efi grub.cfg; do
            [ -s "$BTDIR/$f" ] || boot_assert_fail "Secure Boot chain: $f missing in EFI/BOOT"
        done
        cmp -s "$BTDIR/BOOTX64.EFI" "${IMG_MNT}/usr/lib/shim/shimx64.efi.signed" || boot_assert_fail "EFI/BOOT/BOOTX64.EFI is not the signed shim"
    fi

    if [ "$AB_LAYOUT" = 1 ]; then
        chroot ${IMG_MNT} grub-mkconfig -o "${GRUB_BOOTDIR}/grub/grub.cfg"
        chroot ${IMG_MNT} grub-editenv "${GRUB_BOOTDIR}/grub/grubenv" set saved_entry=slot-a
        grep -q "id 'slot-a'\|--id slot-a\|slot-a" "${IMG_MNT}${GRUB_BOOTDIR}/grub/grub.cfg" \
            || boot_assert_fail "grub.cfg has no slot-a entry"
        grep -q "slot-b" "${IMG_MNT}${GRUB_BOOTDIR}/grub/grub.cfg" \
            || boot_assert_fail "grub.cfg has no slot-b entry"
        # The image carries its own copy of the ESP's grub.cfg: the ESP is not part of a slot, so an
        # update never rewrites it; unitotem-update refreshes it from this file after the new system
        # boots (see sync_esp_grubcfg).
        install -D -m 644 "${IMG_MNT}${GRUB_BOOTDIR}/grub/grub.cfg" "${IMG_MNT}/usr/share/unitotem/esp-grub.cfg"
    else
        chroot ${IMG_MNT} update-grub
    fi

    umount -lf ${IMG_MNT}/dev
    umount -lf ${IMG_MNT}/proc
    umount -lf ${IMG_MNT}/sys
fi

# ---------- Boot-ability assertions ----------
# These checks turn boot failures (missing kernel8.img/dtbs, ...) into build failures while the
# partitions are still mounted.
if [ "$ARCH" = "arm64" ]; then
    FWDIR=${IMG_MNT}/boot/firmware
    SLOTDIR=$FWDIR
    [ "$AB_LAYOUT" = 1 ] && SLOTDIR=$FWDIR/slota

    [ -f "$SLOTDIR/kernel8.img" ] || boot_assert_fail "$SLOTDIR/kernel8.img missing"
    # Two valid kernel8.img formats: a raw arm64 Image ("ARMd" magic at offset 0x38) or a
    # gzip-compressed one (magic 1f8b), which the Pi firmware decompresses at boot and which is
    # what linux-image-rpi-v8 ships.
    magic_gzip=$(dd if="$SLOTDIR/kernel8.img" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$magic_gzip" != "1f8b" ]; then
        magic=$(dd if="$SLOTDIR/kernel8.img" bs=1 skip=56 count=4 2>/dev/null)
        [ "$magic" = "ARMd" ] \
            || boot_assert_fail "kernel8.img is neither a valid raw arm64 Image (magic read: '${magic}', expected 'ARMd' at offset 0x38) nor gzip-compressed (magic: '${magic_gzip}', expected '1f8b')"
    fi

    dtb_count=$(find "$SLOTDIR" -maxdepth 1 -iname "bcm27*.dtb" | wc -l)
    [ "$dtb_count" -gt 0 ] || boot_assert_fail "no bcm27*.dtb in $SLOTDIR"
    for dtb in "$SLOTDIR"/bcm27*.dtb; do
        dtc -I dtb -O dts "$dtb" > /dev/null 2>&1 || boot_assert_fail "$dtb is not a valid dtb (dtc cannot parse it)"
    done

    [ -s "$SLOTDIR/initramfs8" ] || boot_assert_fail "$SLOTDIR/initramfs8 missing or empty"
    # unmkinitramfs, not a hand-rolled decompress: an initramfs can be several concatenated
    # segments (an early uncompressed cpio, then the compressed main archive), and unmkinitramfs
    # handles that and every codec like the kernel's own unpacker. It writes real files, avoiding
    # unreliable `zcat | cpio -t | grep -q` pipes.
    rm -rf /tmp/initramfs8-check
    unmkinitramfs "$SLOTDIR/initramfs8" /tmp/initramfs8-check > /tmp/initramfs8-check.log 2>&1 \
        || boot_assert_fail "$SLOTDIR/initramfs8: unmkinitramfs failed ($(cat /tmp/initramfs8-check.log))"
    # Two valid layouts: unmkinitramfs puts /init in main/ for a multi-segment initramfs, or at the
    # top when it flattens it.
    [ -x /tmp/initramfs8-check/init ] || [ -x /tmp/initramfs8-check/main/init ] \
        || boot_assert_fail "$SLOTDIR/initramfs8 has no /init (neither at the top nor in main/)"
    rm -rf /tmp/initramfs8-check /tmp/initramfs8-check.log

    grep -q "^kernel=" "$FWDIR/config.txt" || boot_assert_fail "config.txt: kernel= missing"
    grep -q "^initramfs .* followkernel" "$FWDIR/config.txt" || boot_assert_fail "config.txt: 'initramfs ... followkernel' missing"
    # Every active dtoverlay must point to a file present in overlays/.
    while read -r ov; do
        [ -f "$SLOTDIR/overlays/${ov}.dtbo" ] \
            || boot_assert_fail "config.txt references dtoverlay=${ov} but $SLOTDIR/overlays/${ov}.dtbo does not exist"
    done < <(awk -F= '/^dtoverlay=/{print $2}' "$FWDIR/config.txt")
fi

if [ "$ARCH" = "amd64" ]; then
    RECOVERY_VMLINUZ_INSTALLED=${IMG_MNT}/boot/efi/unitotem/recovery-vmlinuz
    RECOVERY_INITRD_INSTALLED=${IMG_MNT}/boot/efi/unitotem/recovery-initrd.img
else
    RECOVERY_VMLINUZ_INSTALLED=${IMG_MNT}/boot/firmware/recovery8.img
    RECOVERY_INITRD_INSTALLED=${IMG_MNT}/boot/firmware/recovery-initrd.img
fi
for pair in "$RECOVERY_VMLINUZ:$RECOVERY_VMLINUZ_INSTALLED" "$RECOVERY_INITRD:$RECOVERY_INITRD_INSTALLED"; do
    src="${pair%%:*}"; installed="${pair#*:}"
    [ -f "$installed" ] || boot_assert_fail "$installed missing after the copy"
    expect=$(sha256sum "$src" | cut -d' ' -f1)
    got=$(sha256sum "$installed" | cut -d' ' -f1)
    [ "$expect" = "$got" ] || boot_assert_fail "$installed: sha256 does not match the source artifact ($src)"
done

if [ "$ARCH" = "amd64" ]; then
    BOOTFS_FREE=$(df -B1 --output=avail ${IMG_MNT}/boot/efi | tail -1 | tr -d ' ')
else
    BOOTFS_FREE=$(df -B1 --output=avail ${IMG_MNT}/boot/firmware | tail -1 | tr -d ' ')
fi
[ "$BOOTFS_FREE" -ge $((64 * 1024 * 1024)) ] \
    || boot_assert_fail "less than 64MiB free on the boot partition after all copies ($((BOOTFS_FREE / 1024 / 1024))MiB)"

# ---------- Security-module logging rule ----------
# Either AppArmor is absent from the image, or auditd is installed to take its log: with profiles
# loaded and no audit daemon every denial lands in dmesg and buries the messages that matter.
# Without the `apparmor` package no profile is ever loaded, so the check is on packages.
pkg_installed() { grep -A8 "^Package: $1\$" "${IMG_MNT}/var/lib/dpkg/status" 2>/dev/null | grep -q '^Status: install ok installed'; }
if pkg_installed apparmor; then
    pkg_installed auditd || boot_assert_fail "the apparmor package is installed but auditd is not: all denials would land in dmesg (install and configure auditd, or remove apparmor)"
    echo "apparmor present, auditd present: ok"
else
    echo "apparmor absent from the image: ok (no profile is ever loaded)"
fi

# ---------- Release version ----------
# What unitotem-update compares against the manifest, and what `fetch` re-reads from a freshly written
# slot to make sure it contains the release it was asked for. Written before the baseline below so it
# is part of the pristine image rather than reported as a modification.
mkdir -p ${IMG_MNT}/usr/share/unitotem
echo "${RELEASE_VERSION:-$(date +%Y.%m.%d)}" > ${IMG_MNT}/usr/share/unitotem/release-version

# ---------- Change-detection baseline ----------
# The last thing done to the image: it records what a pristine install looks like, so anything
# written afterwards would be treated as original by unitotem-ota-changes.
# Generated by the same script that later compares against it (unitotem/files/unitotem-ota-changes),
# so both use the same notion of which files are in scope.
echo "Generating the change-detection baseline..."
bash /unitotem/files/unitotem-ota-changes baseline \
    --root "${IMG_MNT}" --out "${IMG_MNT}/usr/lib/unitotem/baseline" \
    || boot_assert_fail "baseline generation failed"

# ---------- Rules every image must satisfy ----------
# All of them run against the finished tree (see unitotem/verify-image.sh for the list and the reasons); a violation fails the
# build instead of shipping. The boot FAT is mounted under ${IMG_MNT}/boot/{efi,firmware} at this point.
echo "Verifying the image against the project rules..."
bash /unitotem/verify-image.sh "${IMG_MNT}" "${ARCH}" "${AB_LAYOUT}" \
    || boot_assert_fail "the image violates one or more rules (see above)"

# ---------- Unmount ----------

sync

umount ${IMG_MNT}/mnt/data
if [ "$ARCH" = "amd64" ]; then
    umount ${IMG_MNT}/boot/efi
    [ -z "$P_BOOT" ] || umount ${IMG_MNT}/boot
elif [ "$ARCH" = "arm64" ]; then
    umount ${IMG_MNT}/boot/firmware
fi
umount ${IMG_MNT}

# fsck after unmount, directly on the loop partitions.
fsck.vfat -n "${LOOP}p${P_BOOTFS}" || boot_assert_fail "fsck.vfat on the boot partition (${LOOP}p${P_BOOTFS}) is not clean"
[ -z "$P_BOOT" ]  || fsck.ext4 -fn "${LOOP}p${P_BOOT}"  || boot_assert_fail "fsck.ext4 on BOOT is not clean"
fsck.ext4 -fn "${LOOP}p${P_ROOT}" || boot_assert_fail "fsck.ext4 on ${ROOT_LABEL} (${LOOP}p${P_ROOT}) is not clean"
[ -z "$P_ROOTB" ] || fsck.ext4 -fn "${LOOP}p${P_ROOTB}" || boot_assert_fail "fsck.ext4 on ROOT_B is not clean"
fsck.ext4 -fn "${LOOP}p${P_DATA}" || boot_assert_fail "fsck.ext4 on DATA (${LOOP}p${P_DATA}) is not clean"

losetup -d "${LOOP}"
trap - EXIT

# ---------- Optional: parts set from this same build ----------
# Off by default; deploy/make-parts.sh is the usual path. With MAKE_PARTS=1 a parts set is made
# from the still-uncompressed ${IMG_FILE}, through its own read-only loop device.
if [ "${MAKE_PARTS:-0}" = 1 ]; then
    echo "Generating parts set (MAKE_PARTS=1)..."
    source /unitotem/deploy-parts-lib.sh
    PARTS_LOOP=$(losetup --find --show --partscan --read-only "${IMG_FILE}")
    trap "losetup -d '${PARTS_LOOP}' 2>/dev/null || true" EXIT
    make_parts "${PARTS_LOOP}" "/deploy/${ARCH}/unitotem-${IMG_DATE}-${ARCH}.parts" \
        "${ARCH}" "unitotem-${IMG_DATE}-${ARCH}" "${IMG_FILE}"
    losetup -d "${PARTS_LOOP}"
    trap - EXIT
fi

# ---------- Flash image (A/B): boot partition(s) + ROOT_A only ----------
# The first boot creates ROOT_B and DATA (layout_complete in unitotem/files/overlayfs-hook.sh). The full image above
# stays the source of the parts set, the release assets and the network deploy.
if [ "$AB_LAYOUT" = 1 ]; then
    FLASH_IMG="/deploy/${ARCH}/unitotem-${IMG_DATE}-${ARCH}-flash.img"
    bash /unitotem/make-flash-image.sh "${IMG_FILE}" "${FLASH_IMG}"
    rm -f "${FLASH_IMG}.xz"
    xz -v -T0 "${FLASH_IMG}"
fi

# ---------- Compress ----------

echo "Compressing image..."
rm -f "${IMG_FILE}.xz"   # a same-day rerun would otherwise make plain xz refuse to overwrite
xz -v -T0 "${IMG_FILE}"

echo "=== Stage 3 complete: ${IMG_FILE}.xz ==="

#!/bin/bash
set -euo pipefail
source /kiosk/common.sh

echo "=== Stage 3: Disk Image Creation (ARCH=${ARCH}) ==="

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}" "/deploy/${ARCH}"

echo "Extracting stage 2..."
tar -I pigz -C "${ROOTFS}" -xf "${WORK_DIR}/stage2.tar.gz"

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

# Partition numbers differ between layouts, so name them once and use the names below.
# Single-ROOT: amd64 EFI/BOOT/ROOT/DATA, arm64 FIRMWARE/ROOT/DATA.
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
    parted -s "${IMG_FILE}" mklabel gpt
    parted -s "${IMG_FILE}" mkpart FIRMWARE fat32  "${FW_START_MIB}M"  "${FW_END_MIB}M"
    if [ "$AB_LAYOUT" = 1 ]; then
        SLOT_MIB=$(size_to_mib "$ROOT_SLOT_SIZE")
        A_END_MIB=$((FW_END_MIB + SLOT_MIB))
        B_END_MIB=$((A_END_MIB + SLOT_MIB))
        # MiB, not M: parted's bare "M" is 10^6 bytes, which leaves every boundary
        # misaligned (and the slots a few percent smaller than asked). The single-ROOT
        # branch keeps "M" so its layout stays byte-identical to what is deployed.
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
# Slot B starts empty but formatted and labelled, so the layout is complete from day one and
# the first update only has to write into it.
[ -z "$P_ROOTB" ] || mkfs.ext4 -F -L ROOT_B "${LOOP}p${P_ROOTB}"
# DATA keeps its journal. It was created without one (^has_journal) to spare the SD card; a forced power-cut test
# then found state files read back as NULs and a directory entry missing, with no journal to replay and no fsck
# at boot: freed blocks were reused while the on-disk bitmap still showed them free. A power loss on an
# appliance is the normal case, so DATA gets crash consistency (data=ordered, the ext4 default).
mkfs.ext4 -F -L DATA "${LOOP}p${P_DATA}"

boot_assert_fail() { echo "BOOT-ABILITY CHECK FAILED: $*" >&2; exit 1; }

# ---------- Mount & populate ----------

# Not redundant now that IMG_MNT is overridable: /mnt always exists, an
# arbitrary override path does not, and mount fails outright on a missing
# mountpoint.
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
    mkdir -p ${IMG_MNT}/boot/efi/unitotem
    cp "$RECOVERY_VMLINUZ" ${IMG_MNT}/boot/efi/unitotem/recovery-vmlinuz
    cp "$RECOVERY_INITRD"  ${IMG_MNT}/boot/efi/unitotem/recovery-initrd.img
    {
        echo "$(sha256sum "$RECOVERY_VMLINUZ" | cut -d' ' -f1)  recovery-vmlinuz"
        echo "$(sha256sum "$RECOVERY_INITRD"  | cut -d' ' -f1)  recovery-initrd.img"
    } > ${IMG_MNT}/boot/efi/unitotem/recovery.sha256
elif [ "$ARCH" = "arm64" ]; then
    cp "$RECOVERY_VMLINUZ" ${IMG_MNT}/boot/firmware/recovery8.img
    cp "$RECOVERY_INITRD"  ${IMG_MNT}/boot/firmware/recovery-initrd.img
    {
        echo "$(sha256sum "$RECOVERY_VMLINUZ" | cut -d' ' -f1)  recovery8.img"
        echo "$(sha256sum "$RECOVERY_INITRD"  | cut -d' ' -f1)  recovery-initrd.img"
    } > ${IMG_MNT}/boot/firmware/recovery.sha256
fi

# ---------- A/B on arm64: kernel, initramfs, dtbs and cmdline go in a per-slot directory ----------
# `os_prefix=slota/` in config.txt makes the firmware read kernel, initramfs, dtbs, overlays and
# cmdline.txt from that subdirectory; the firmware proper (start*.elf, fixup*.dat, bootcode.bin)
# and config.txt stay at the top. Slot B's directory is written by the first update. Whether
# the Pi 4 firmware honours os_prefix for every one of those files is UNVERIFIED on hardware
# (AB-DESIGN.md) - the build only arranges the files so that test can be done.
if [ "$ARCH" = "arm64" ] && [ "$AB_LAYOUT" = 1 ]; then
    FW=${IMG_MNT}/boot/firmware
    mkdir -p "$FW/slota"
    for f in kernel8.img initramfs8 cmdline.txt; do
        [ -e "$FW/$f" ] && mv "$FW/$f" "$FW/slota/$f"
    done
    # dtbs and overlays are COPIED, not moved: slot A boots through os_prefix=slota/ and finds its own, but the
    # resident fallback (config.txt without os_prefix: kernel=recovery8.img) loads its device tree from the TOP of the
    # partition. Moving them left the fallback with no dtb, and a Pi that boots a kernel without one stops at the rainbow
    # screen - the safety net itself was unbootable (found on the first real Pi deploy).
    cp -r "$FW/overlays" "$FW/slota/overlays" 2>/dev/null || true
    for f in "$FW"/*.dtb; do [ -e "$f" ] && cp "$f" "$FW/slota/"; done
    sed -i '0,/^\[all\]/s//[all]\nos_prefix=slota\//' "$FW/config.txt"
    grep -q '^os_prefix=slota/' "$FW/config.txt" || { echo "config.txt: os_prefix non inserito" >&2; exit 1; }
    # the fallback's device tree must stay where its config.txt (no os_prefix) looks for it
    [ -s "$FW/bcm2711-rpi-4-b.dtb" ] || { echo "BOOT-ABILITY: manca bcm2711-rpi-4-b.dtb al primo livello: il fallback non potrebbe avviarsi" >&2; exit 1; }
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

    # BIOS: embeds core.img into the ef02 partition carved out above and
    # writes the MBR boot code, so the same disk boots on both UEFI and
    # legacy BIOS firmware - matters for deploy/remote-deploy.sh, which
    # can't make a BIOS target bootable on its own if the image itself
    # never shipped BIOS support.
    chroot ${IMG_MNT} grub-install \
        --target=i386-pc \
        --boot-directory="${GRUB_BOOTDIR}" \
        "${LOOP}"

    # (--no-uefi-secure-boot above matters: with shim-signed and grub-efi-amd64-signed installed, Debian's grub-install otherwise puts
    # shim at EFI/BOOT/BOOTX64.EFI and the signed GRUB beside it by itself, which is not the "plain GRUB by default" this relies on;
    # found by the verify-image check below on the 2026-10-12 build.)
    # Secure Boot chain, staged but NOT active: EFI/BOOT/BOOTX64.EFI stays the unsigned GRUB (grub-install --removable above), which
    # is what a machine without Secure Boot needs. The deploy swaps in this chain (shim as BOOTX64.EFI) only when the target has
    # Secure Boot enabled and the operator chose "install with shim" (ota-engine populate-bootfs --secure-boot shim). The signed
    # GRUB has a fixed prefix and cannot be pointed elsewhere at install time, so it finds only grub.cfg stubs, which hand over to
    # the real configuration (grub.cfg + grubenv, unitotem-grub/ on this same partition).
    if [ "$AB_LAYOUT" = 1 ]; then
        SBDIR=${IMG_MNT}/boot/efi/EFI/unitotem-sb
        mkdir -p "$SBDIR"
        cp "${IMG_MNT}/usr/lib/shim/shimx64.efi.signed"                      "$SBDIR/shimx64.efi"
        cp "${IMG_MNT}/usr/lib/shim/mmx64.efi.signed"                        "$SBDIR/mmx64.efi"
        cp "${IMG_MNT}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"    "$SBDIR/grubx64.efi"
        cp "${IMG_MNT}/boot/efi/EFI/BOOT/BOOTX64.EFI"                        "$SBDIR/grub-unsigned.efi"
        cat > "$SBDIR/grub.cfg" << 'SBEOF'
# UniTotem Secure Boot stub: hands over to the real GRUB configuration on this ESP.
search --no-floppy --label --set=root EFI
set prefix=($root)/unitotem-grub/grub
configfile ($root)/unitotem-grub/grub/grub.cfg
SBEOF
        for f in shimx64.efi mmx64.efi grubx64.efi grub-unsigned.efi grub.cfg; do
            [ -s "$SBDIR/$f" ] || boot_assert_fail "catena Secure Boot: $f assente in EFI/unitotem-sb"
        done
    fi

    if [ "$AB_LAYOUT" = 1 ]; then
        chroot ${IMG_MNT} grub-mkconfig -o "${GRUB_BOOTDIR}/grub/grub.cfg"
        chroot ${IMG_MNT} grub-editenv "${GRUB_BOOTDIR}/grub/grubenv" set saved_entry=slot-a
        grep -q "id 'slot-a'\|--id slot-a\|slot-a" "${IMG_MNT}${GRUB_BOOTDIR}/grub/grub.cfg" \
            || boot_assert_fail "grub.cfg non contiene la voce slot-a"
        grep -q "slot-b" "${IMG_MNT}${GRUB_BOOTDIR}/grub/grub.cfg" \
            || boot_assert_fail "grub.cfg non contiene la voce slot-b"
    else
        chroot ${IMG_MNT} update-grub
    fi

    umount -lf ${IMG_MNT}/dev
    umount -lf ${IMG_MNT}/proc
    umount -lf ${IMG_MNT}/sys
fi

# ---------- Boot-ability assertions ----------
# The arm64 image previously shipped and only failed to boot on real
# hardware after the fact (missing kernel8.img/dtbs - see the OTA redesign
# plan's Context). These checks turn that class of bug into a build failure
# instead, while the relevant partitions are still mounted and cheap to
# inspect.

if [ "$ARCH" = "arm64" ]; then
    FWDIR=${IMG_MNT}/boot/firmware
    SLOTDIR=$FWDIR
    [ "$AB_LAYOUT" = 1 ] && SLOTDIR=$FWDIR/slota

    [ -f "$SLOTDIR/kernel8.img" ] || boot_assert_fail "$SLOTDIR/kernel8.img assente"
    # Two valid formats here, not one: a raw uncompressed arm64 Image
    # ("ARMd" magic at offset 0x38 - what the generic Debian kernel this
    # project used to ship produced), or a gzip-compressed one (magic
    # 1f8b at offset 0) - the Pi firmware bootloader (start4.elf etc.)
    # decompresses gzip kernel8.img on the fly at boot, and that is
    # exactly the format linux-image-rpi-v8's own vmlinuz ships in
    # (confirmed directly against the real package, not assumed). Accept
    # either; only reject a file that is neither.
    magic_gzip=$(dd if="$SLOTDIR/kernel8.img" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$magic_gzip" != "1f8b" ]; then
        magic=$(dd if="$SLOTDIR/kernel8.img" bs=1 skip=56 count=4 2>/dev/null)
        [ "$magic" = "ARMd" ] \
            || boot_assert_fail "kernel8.img non e' ne' un Image arm64 grezzo valido (magic letto: '${magic}', atteso 'ARMd' a offset 0x38) ne' gzip-compresso (magic: '${magic_gzip}', atteso '1f8b')"
    fi

    dtb_count=$(find "$SLOTDIR" -maxdepth 1 -iname "bcm27*.dtb" | wc -l)
    [ "$dtb_count" -gt 0 ] || boot_assert_fail "nessun bcm27*.dtb su $SLOTDIR"
    for dtb in "$SLOTDIR"/bcm27*.dtb; do
        dtc -I dtb -O dts "$dtb" > /dev/null 2>&1 || boot_assert_fail "$dtb non e' un dtb valido (dtc non riesce a parsarlo)"
    done

    [ -s "$SLOTDIR/initramfs8" ] || boot_assert_fail "$SLOTDIR/initramfs8 assente o vuoto"
    # unmkinitramfs, not a hand-rolled decompress-then-cpio-t: an initramfs is
    # not necessarily one compressed stream. mkinitramfs concatenates segments
    # - an early, uncompressed cpio (hooks that must run before the main
    # archive; on trixie/arm64 this is raspi-firmware's own early hook,
    # confirmed by reproducing the exact build in a clean container and
    # watching mkinitramfs -v name it) followed by the real, compressed main
    # archive. Reading only the first few bytes - what this check used to do,
    # by magic number, gzip-only at first and then extended to try zstd/xz -
    # was checking the small early segment's format, never the compressed
    # body, and would keep breaking at the next hook or compressor default
    # change. unmkinitramfs already contains the real concatenation-and-
    # multi-codec logic (gzip/zstd/xz/lz4/raw, any number of segments) -
    # written once, matching what the kernel's own initramfs unpacker does at
    # actual boot, not reimplemented here to chase it.
    #
    # A previous version of this check also read a live
    # `zcat | cpio -t | grep -q` pipe rather than a file, and that pipe form
    # was independently confirmed unreliable - intermittently reporting no
    # /init on a file that a sequential decompress-then-list of the exact same
    # bytes read cleanly, repeatably. unmkinitramfs writes real files to a
    # directory, sidestepping that class of problem too.
    rm -rf /tmp/initramfs8-check
    unmkinitramfs "$SLOTDIR/initramfs8" /tmp/initramfs8-check > /tmp/initramfs8-check.log 2>&1 \
        || boot_assert_fail "$SLOTDIR/initramfs8: unmkinitramfs fallito ($(cat /tmp/initramfs8-check.log))"
    # Two valid layouts, not one: unmkinitramfs splits a genuinely
    # multi-segment initramfs into early/ and main/ subdirectories, with
    # /init inside main/ - confirmed by pulling the ACTUAL file this build
    # produced (with the real, full package set: X11, chromium, pipewire, not
    # a minimal stand-in) straight off the Pi and extracting it there. A
    # smaller reproduction built earlier from just the kernel + raspi-firmware
    # had unmkinitramfs flatten everything with /init at the top instead -
    # different real behavior for a different real input, not one right
    # answer and one wrong guess, so both are checked rather than picking the
    # one that happened to match the most recent test.
    [ -x /tmp/initramfs8-check/init ] || [ -x /tmp/initramfs8-check/main/init ] \
        || boot_assert_fail "$SLOTDIR/initramfs8 non contiene /init (ne' in cima ne' in main/)"
    rm -rf /tmp/initramfs8-check /tmp/initramfs8-check.log

    grep -q "^kernel=" "$FWDIR/config.txt" || boot_assert_fail "config.txt: manca kernel="
    grep -q "^initramfs .* followkernel" "$FWDIR/config.txt" || boot_assert_fail "config.txt: manca 'initramfs ... followkernel'"
    # Nessun dtoverlay attivo deve puntare a un file assente in overlays/ - il
    # pacchetto kernel Debian generico non ne spedisce nessuno (vedi il
    # follow-up "passare a linux-image-rpi-v8" nella documentazione OTA).
    while read -r ov; do
        [ -f "$SLOTDIR/overlays/${ov}.dtbo" ] \
            || boot_assert_fail "config.txt referenzia dtoverlay=${ov} ma $SLOTDIR/overlays/${ov}.dtbo non esiste"
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
    [ -f "$installed" ] || boot_assert_fail "$installed assente dopo la copia"
    expect=$(sha256sum "$src" | cut -d' ' -f1)
    got=$(sha256sum "$installed" | cut -d' ' -f1)
    [ "$expect" = "$got" ] || boot_assert_fail "$installed: sha256 non corrisponde all'artefatto sorgente ($src)"
done

if [ "$ARCH" = "amd64" ]; then
    BOOTFS_FREE=$(df -B1 --output=avail ${IMG_MNT}/boot/efi | tail -1 | tr -d ' ')
else
    BOOTFS_FREE=$(df -B1 --output=avail ${IMG_MNT}/boot/firmware | tail -1 | tr -d ' ')
fi
[ "$BOOTFS_FREE" -ge $((64 * 1024 * 1024)) ] \
    || boot_assert_fail "meno di 64MiB liberi sulla partizione di boot dopo tutte le copie ($((BOOTFS_FREE / 1024 / 1024))MiB)"

# ---------- Security-module logging rule ----------
# Either AppArmor is absent from the image, or auditd is installed to take its log. With AppArmor profiles loaded and no
# audit daemon, every denial is printed by the kernel and lands in dmesg, burying the messages that matter (user rule,
# 2026-10-11). The kernel merely containing AppArmor is not the issue - without the `apparmor` package no profile is ever
# loaded - so the check is on packages. `apparmor=0` on the kernel command line would also satisfy "disabled", but
# nothing here sets it, so it is not accepted silently.
pkg_installed() { grep -A8 "^Package: $1\$" "${IMG_MNT}/var/lib/dpkg/status" 2>/dev/null | grep -q '^Status: install ok installed'; }
if pkg_installed apparmor; then
    pkg_installed auditd || boot_assert_fail "il pacchetto apparmor e' installato ma auditd no: le violazioni finirebbero tutte in dmesg (installare auditd e configurarlo, oppure togliere apparmor)"
    echo "apparmor presente, auditd presente: ok"
else
    echo "apparmor assente dall'immagine: ok (nessun profilo verra' mai caricato)"
fi

# ---------- Release version ----------
# What unitotem-update compares against the manifest, and what `fetch` re-reads from a freshly written
# slot to make sure it contains the release it was asked for. Written before the baseline below so it
# is part of the pristine image rather than reported as a modification.
mkdir -p ${IMG_MNT}/usr/share/unitotem
echo "${RELEASE_VERSION:-$(date +%Y.%m.%d)}" > ${IMG_MNT}/usr/share/unitotem/release-version

# ---------- Change-detection baseline ----------
# Deliberately the last thing done to the image: it records what a pristine
# install looks like, so anything written afterwards would be baked in as
# "original" and become invisible to unitotem-ota-changes forever.
#
# Generated by the same script that later compares against it
# (kiosk/files/unitotem-ota-changes), rather than by a build-time equivalent -
# two implementations of "which files are in scope" would drift, and the drift
# would surface as phantom modifications on every deployed device.
echo "Genero la baseline di rilevazione modifiche..."
bash /kiosk/files/unitotem-ota-changes baseline \
    --root "${IMG_MNT}" --out "${IMG_MNT}/usr/lib/unitotem/baseline" \
    || boot_assert_fail "generazione della baseline fallita"

# ---------- Rules every image must satisfy ----------
# All of them run against the finished tree (see kiosk/verify-image.sh for the list and the reasons); a violation fails the
# build instead of shipping. The boot FAT is mounted under ${IMG_MNT}/boot/{efi,firmware} at this point.
echo "Verifying the image against the project rules..."
bash /kiosk/verify-image.sh "${IMG_MNT}" "${ARCH}" "${AB_LAYOUT}" \
    || boot_assert_fail "l'immagine viola una o piu' regole (vedi sopra)"

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

# fsck after unmount, directly on the loop partitions - a mounted (even
# read-only-checked) filesystem doesn't give fsck a reliable view.
fsck.vfat -n "${LOOP}p${P_BOOTFS}" || boot_assert_fail "fsck.vfat sulla partizione di boot (${LOOP}p${P_BOOTFS}) non pulito"
[ -z "$P_BOOT" ]  || fsck.ext4 -fn "${LOOP}p${P_BOOT}"  || boot_assert_fail "fsck.ext4 su BOOT non pulito"
fsck.ext4 -fn "${LOOP}p${P_ROOT}" || boot_assert_fail "fsck.ext4 su ${ROOT_LABEL} (${LOOP}p${P_ROOT}) non pulito"
[ -z "$P_ROOTB" ] || fsck.ext4 -fn "${LOOP}p${P_ROOTB}" || boot_assert_fail "fsck.ext4 su ROOT_B non pulito"
fsck.ext4 -fn "${LOOP}p${P_DATA}" || boot_assert_fail "fsck.ext4 su DATA (${LOOP}p${P_DATA}) non pulito"

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

#!/bin/bash
# Minimal "preboot" SD image for a Raspberry Pi (arm64): the resident OTA fallback and nothing else.
#
#   deploy/make-preboot-image.sh [--parts DIR] [--recovery-dir DIR] [--out FILE] [--size-mib N] [--no-xz]
#
# Write the result to an SD card (dd / balenaEtcher / rpi-imager "use custom"), put it in the Pi and power on: the board boots the fallback
# kernel + initramfs from RAM (the same environment a deployed device falls back to), gets an address by DHCP on every wired interface, shows
# it on screen and waits (no idle timeout) for the host, which then writes the real system:
#
#   deploy/remote-deploy.sh recover <address-shown-on-screen> --parts deploy/arm64/<parts set> --yes
#
# `recover` finds no UniTotem partitions on this card, so it lays the whole card out from scratch (partition table, boot partition, slots A
# and B, DATA) and reboots into the real system. Nothing on the card is kept (there is nothing to keep).
#
# Contents of the one FAT partition (MBR, type 0c, from 1 MiB): the Raspberry Pi firmware (start*.elf, fixup*.dat, bootcode.bin, the device
# trees) taken from the parts set's own boot partition, the fallback kernel + initramfs from deploy/arm64/recovery-*, config.txt and
# cmdline.txt. No overlays and no slot directories: the fallback drives the firmware framebuffer (nomodeset-style) and needs only a console
# and the network. About 60 MiB of content; the default image is 128 MiB.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH=arm64
PARTS="" REC="${DIR}/deploy/arm64" OUT="" SIZE_MIB=128 XZ=1
while [ $# -gt 0 ]; do
    case "$1" in
        --parts) PARTS="$2"; shift 2 ;;
        --recovery-dir) REC="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --size-mib) SIZE_MIB="$2"; shift 2 ;;
        --no-xz) XZ=0; shift ;;
        *) echo "Opzione sconosciuta: $1" >&2; exit 1 ;;
    esac
done
for c in sfdisk mkfs.fat mcopy dd tar xz truncate; do command -v "$c" >/dev/null || { echo "manca il comando $c" >&2; exit 1; }; done
[ -n "$PARTS" ] || PARTS=$(ls -td "${DIR}/deploy/${ARCH}/"*.parts 2>/dev/null | head -1)
[ -d "$PARTS" ] || { echo "nessun parts set arm64 (usa --parts)" >&2; exit 1; }
VMLINUZ="${REC}/recovery-vmlinuz-${ARCH}"; INITRD="${REC}/recovery-initrd-${ARCH}.img"
[ -s "$VMLINUZ" ] && [ -s "$INITRD" ] || { echo "manca ${VMLINUZ} o ${INITRD}" >&2; exit 1; }
TARBALL=$(ls "${PARTS}"/p1-FIRMWARE.bootfs.tar.* 2>/dev/null | head -1)
[ -s "$TARBALL" ] || { echo "il parts set non ha p1-FIRMWARE.bootfs.tar.*" >&2; exit 1; }
[ -n "$OUT" ] || OUT="${DIR}/deploy/${ARCH}/unitotem-preboot-${ARCH}.img"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/preboot.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
FW="$WORK/fw"; mkdir -p "$FW"

# firmware files only: not the slot directories, not the real kernel/initramfs, not the overlays
tar -C "$FW" -xf "$TARBALL" --wildcards --no-wildcards-match-slash --no-same-owner \
    './bootcode.bin' './start*.elf' './fixup*.dat' './*.dtb' './LICENCE.broadcom' 2>/dev/null || true
# the Pi 3/4 firmware and the device trees are what the boards that run arm64 UniTotem need; drop the extra start*_x/_db variants
rm -f "$FW"/start_x.elf "$FW"/start4x.elf "$FW"/start_db.elf "$FW"/start4db.elf "$FW"/fixup_x.dat "$FW"/fixup4x.dat "$FW"/fixup_db.dat "$FW"/fixup4db.dat
for need in start4.elf fixup4.dat bcm2711-rpi-4-b.dtb; do
    [ -s "$FW/$need" ] || { echo "il parts set non contiene $need" >&2; exit 1; }
done
cp -- "$VMLINUZ" "$FW/recovery8.img"
cp -- "$INITRD" "$FW/recovery-initrd.img"
# Same description as the resident fallback of a deployed device (ota-engine.sh set-default-recovery): 640x480 DMT mode so the text is
# readable from a distance on any monitor. ttyS0 is the header UART of Raspberry Pi's own device trees.
cat > "$FW/config.txt" <<'EOF'
arm_64bit=1
enable_uart=1
hdmi_group=2
hdmi_mode=4
kernel=recovery8.img
initramfs recovery-initrd.img followkernel
EOF
# unitotem.ota=recover: wait for the host with NO idle timeout (unitotem.ota=1 reboots after 30 minutes without a host)
echo "unitotem.ota=recover console=tty1 console=ttyS0,115200" > "$FW/cmdline.txt"

CONTENT_KB=$(du -sk "$FW" | cut -f1)
[ $((SIZE_MIB * 1024)) -gt $((CONTENT_KB + 8192)) ] || { echo "contenuto ${CONTENT_KB} KiB: serve --size-mib piu' grande" >&2; exit 1; }

# FAT32 partition from 1 MiB to the end (MBR: the firmware of every Pi reads it; FAT32 needs >= ~33 MiB)
FAT_MIB=$((SIZE_MIB - 1))
rm -f -- "$OUT"; truncate -s "${SIZE_MIB}M" "$OUT"
printf 'label: dos\nunit: sectors\n\nstart=2048, size=%d, type=c, bootable\n' $((FAT_MIB * 2048)) | sfdisk -q "$OUT"
truncate -s "${FAT_MIB}M" "$WORK/fat.img"
mkfs.fat -F32 -n FIRMWARE -i 50524550 "$WORK/fat.img" >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -i "$WORK/fat.img" -s "$FW"/* ::/
dd if="$WORK/fat.img" of="$OUT" bs=1M seek=1 conv=notrunc status=none
echo ">>> ${OUT}: $(du -h --apparent-size "$OUT" | cut -f1), contenuto ${CONTENT_KB} KiB, parts $(basename "$PARTS")"
if [ "$XZ" = 1 ]; then
    xz -T0 -f -k -- "$OUT"
    echo ">>> ${OUT}.xz: $(du -h "${OUT}.xz" | cut -f1)"
fi

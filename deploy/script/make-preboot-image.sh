#!/bin/bash
# Minimal "preboot" SD image for a Raspberry Pi (arm64): the OTA fallback and nothing else.
#
# One FAT partition (MBR, type 0c, from 1 MiB): the Pi firmware, the recovery kernel and initrd and the device trees, all read from the boot
# partition of the arm64 image given with --image; config.txt and cmdline.txt (unitotem.ota=recover). The engine in the initrd is replaced by
# --engine. The Pi boots it, gets an address by DHCP, shows it and waits for `remote-deploy.sh deploy <address> --image FILE`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { cat <<'USAGE'
Usage: make-preboot-image.sh --image FILE [options]

  --image FILE      arm64 image: firmware, recovery kernel and initrd
  --out FILE        result (./unitotem-preboot-arm64.img)
  --engine FILE     engine put in the initrd (ota-engine.sh beside this)
  --size-mib N      card image size (128)
  --no-xz           no .xz copy

Needs root. Docs: docs/system/deploy-and-recovery.md
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
# Runs this script again as root through sudo, with the variables it reads (sudo-rs ignores -E): the OTA_* credentials, UNITOTEM_*,
# the state directory, the ssh agent and the locale. sudo keeps the working directory.
reexec_as_root() {
    local v vars=("HOME=${HOME}")
    for v in $(compgen -e); do
        case "$v" in OTA_*|UNITOTEM_*|XDG_STATE_HOME|SSH_AUTH_SOCK|SSHPASS|TERM|LANG|LC_*|TMPDIR) vars+=("${v}=${!v}") ;; esac
    done
    exec sudo env "${vars[@]}" "${BASH}" "$@"
}
[ "$(id -u)" = 0 ] || reexec_as_root "${BASH_SOURCE[0]}" "$@"
ARCH=arm64
IMAGE="" ENGINE="${HERE}/ota-engine.sh" OUT="./unitotem-preboot-arm64.img" SIZE_MIB=128 XZ=1
while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --engine) ENGINE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --size-mib) SIZE_MIB="$2"; shift 2 ;;
        --no-xz) XZ=0; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
for c in sfdisk mkfs.fat mcopy dd tar xz truncate cpio install; do command -v "$c" >/dev/null || { echo "missing command $c" >&2; exit 1; }; done
source "${HERE}/image-lib.sh"
[ -f "$IMAGE" ] || { echo "--image FILE is required (an arm64 image)" >&2; exit 1; }
[ -f "$ENGINE" ] || { echo "engine not found: $ENGINE" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/preboot.XXXXXX")
trap 'image_close; rm -rf -- "$WORK"' EXIT
FW="$WORK/fw"; mkdir -p "$FW"

# firmware files only: not the slot directories, not the real kernel/initramfs, not the overlays
image_open "$IMAGE" || { echo "cannot open $IMAGE" >&2; exit 1; }
FWNODE=""; for n in 1 2; do d=$(image_node "$n") && [ "$(blkid -s LABEL -o value "$d")" = FIRMWARE ] && FWNODE=$d && break; done
[ -n "$FWNODE" ] || { echo "the image has no FIRMWARE partition" >&2; exit 1; }
SRC="$WORK/src"; mkdir -p "$SRC"; mount -t vfat -o ro "$FWNODE" "$SRC"
( shopt -s nullglob; cd "$SRC" && for f in bootcode.bin start*.elf fixup*.dat *.dtb LICENCE.broadcom; do [ -f "$f" ] && cp -- "$f" "$FW/"; done; true )
VMLINUZ="$WORK/recovery8.img"; INITRD="$WORK/recovery-initrd.img"
cp -- "$SRC/recovery8.img" "$VMLINUZ" 2>/dev/null; cp -- "$SRC/recovery-initrd.img" "$INITRD" 2>/dev/null
[ -s "$VMLINUZ" ] && [ -s "$INITRD" ] || { umount "$SRC"; echo "the image has no recovery8.img and recovery-initrd.img on its boot partition" >&2; exit 1; }
umount "$SRC"
# the Pi 3/4 firmware and the device trees are what the boards that run arm64 UniTotem need; drop the extra start*_x/_db variants
rm -f "$FW"/start_x.elf "$FW"/start4x.elf "$FW"/start_db.elf "$FW"/start4db.elf "$FW"/fixup_x.dat "$FW"/fixup4x.dat "$FW"/fixup_db.dat "$FW"/fixup4db.dat
for need in start.elf fixup.dat bcm2710-rpi-3-b.dtb start4.elf fixup4.dat bcm2711-rpi-4-b.dtb; do
    [ -s "$FW/$need" ] || { echo "the image does not contain $need" >&2; exit 1; }
done
cp -- "$VMLINUZ" "$FW/recovery8.img"
cp -- "$INITRD" "$FW/recovery-initrd.img"
# The engine of the preboot image is the repository's, whatever engine the stored recovery initrd was built with: a second cpio archive
# with just that file is appended; the kernel unpacks the archives in order and a later entry replaces an earlier one.
OV="$WORK/ov"; mkdir -p "$OV/usr/lib/unitotem"
install -m 755 -- "$ENGINE" "$OV/usr/lib/unitotem/ota-engine.sh"
( cd "$OV" && printf 'usr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet --owner=0:0 ) >> "$FW/recovery-initrd.img"
# Same settings as the resident fallback of a deployed device (ota-engine.sh set-default-recovery): 640x480 DMT mode so the
# text is readable from a distance. ttyS0 is the header UART.
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
[ $((SIZE_MIB * 1024)) -gt $((CONTENT_KB + 8192)) ] || { echo "content is ${CONTENT_KB} KiB: a larger --size-mib is needed" >&2; exit 1; }

# FAT32 partition from 1 MiB to the end (MBR: the firmware of every Pi reads it; FAT32 needs >= ~33 MiB)
FAT_MIB=$((SIZE_MIB - 1))
rm -f -- "$OUT"; truncate -s "${SIZE_MIB}M" "$OUT"
printf 'label: dos\nunit: sectors\n\nstart=2048, size=%d, type=c, bootable\n' $((FAT_MIB * 2048)) | sfdisk -q "$OUT"
truncate -s "${FAT_MIB}M" "$WORK/fat.img"
mkfs.fat -F32 -n FIRMWARE -i 50524550 "$WORK/fat.img" >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -i "$WORK/fat.img" -s "$FW"/* ::/
dd if="$WORK/fat.img" of="$OUT" bs=1M seek=1 conv=notrunc status=none
echo ">>> ${OUT}: $(du -h --apparent-size "$OUT" | cut -f1), content ${CONTENT_KB} KiB, image $(basename "$IMAGE")"
if [ "$XZ" = 1 ]; then
    xz -T0 -f -k -- "$OUT"
    echo ">>> ${OUT}.xz: $(du -h "${OUT}.xz" | cut -f1)"
fi

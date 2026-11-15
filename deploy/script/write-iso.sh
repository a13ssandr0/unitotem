#!/bin/bash
# Writes a hybrid installer ISO (BIOS and UEFI bootable) to a USB stick or disk: the whole file is copied to the device, then read back and compared.
#
#   write-iso.sh [--yes] [--no-eject] ISO DEVICE
#
#   ISO     unitotem-installer-<date>-amd64.iso
#   DEVICE  whole disk, e.g. /dev/sdb: everything on it is lost
#
# Needs root. Refuses a device with mounted partitions, the disk holding / or /boot, a device with no medium and one smaller than the ISO.
# Without --yes the device is shown and a (y/n) confirmation is read from the terminal. A removable device is ejected at the end.
set -euo pipefail
usage() { cat <<'USAGE'
Usage: write-iso.sh [--yes] [--no-eject] ISO DEVICE

  ISO      installer ISO
  DEVICE   whole disk, e.g. /dev/sdb: everything on it is lost

Needs root. The copy is read back and compared.
Docs: docs/system/installer-iso.md
USAGE
}
log() { printf '%s %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" "$2" >&2; }
die() { log ERROR "$1"; exit 1; }

YES=0 EJECT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1; shift ;;
        --no-eject) EJECT=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || { usage >&2; exit 1; }
ISO=$1 DEVICE=$2

[ "$(id -u)" = 0 ] || die "must run as root"
for t in lsblk findmnt dd pv cmp blockdev; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
[ -f "$ISO" ] || die "ISO not found: $ISO"
[ -b "$DEVICE" ] || die "not a block device: $DEVICE"
case "$(lsblk -dno TYPE -- "$DEVICE")" in disk|loop) ;; *) die "$DEVICE is not a whole disk" ;; esac
# the size comes from sysfs (no I/O): an ioctl on an empty card-reader slot can sit in the kernel for minutes
SECTORS=$(cat "/sys/class/block/$(basename -- "$DEVICE")/size" 2>/dev/null || echo 0)
[ "$SECTORS" -gt 0 ] || die "$DEVICE has no medium (size 0): insert the stick or reseat the reader"
SIZE=$(stat -c %s -- "$ISO")
[ $((SECTORS * 512)) -ge "$SIZE" ] || die "$DEVICE is $((SECTORS * 512 / 1048576)) MiB, the ISO is $((SIZE / 1048576)) MiB"
[ -z "$(lsblk -nro MOUNTPOINTS -- "$DEVICE" | tr -d ' \n')" ] || die "$DEVICE has mounted partitions: unmount them first"
for mp in / /boot /boot/efi; do
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null || true)
    [ -n "$src" ] || continue
    parent=$(lsblk -no PKNAME -- "$src" 2>/dev/null | head -1 || true)
    [ "/dev/${parent}" = "$DEVICE" ] && die "$DEVICE holds $mp"
done

if [ "$YES" != 1 ]; then
    lsblk -o NAME,SIZE,MODEL,TRAN,TYPE -- "$DEVICE" >&2
    printf 'Erase %s and write %s? (y/n) ' "$DEVICE" "$ISO" >&2
    read -r answer
    case "${answer,,}" in y|yes) ;; *) die "cancelled" ;; esac
fi

START=$(date +%s)
log INFO "writing $(basename -- "$ISO") ($((SIZE / 1048576)) MiB) to $DEVICE"
pv -N iso -s "$SIZE" -- "$ISO" | dd of="$DEVICE" bs=4M conv=fsync status=none
st=("${PIPESTATUS[@]}")
{ [ "${st[0]}" = 0 ] && [ "${st[1]}" = 0 ]; } || die "the copy failed"
sync
blockdev --flushbufs "$DEVICE" 2>/dev/null || true
log INFO "reading back"
dd if="$DEVICE" bs=4M count="$SIZE" iflag=count_bytes status=none | pv -N verify -s "$SIZE" | cmp -s -- - "$ISO" \
    || die "the data read back differs from the ISO"
log INFO "done and verified in $(( $(date +%s) - START )) s: $DEVICE"
if [ "$EJECT" = 1 ] && [ "$(lsblk -dno RM -- "$DEVICE" | tr -d ' ')" = 1 ]; then
    command -v eject >/dev/null 2>&1 && eject -- "$DEVICE" 2>/dev/null && log INFO "ejected $DEVICE: the stick can be removed" \
        || log WARN "cannot eject $DEVICE: unmount it from the desktop before removing it"
fi

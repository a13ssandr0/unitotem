#!/bin/bash
# Writes a UniTotem disk image (full, flash or Raspberry Pi) to an SD card or disk: creates the partition table, creates the
# partitions, then clones every partition with partclone, so only the blocks in use are copied (an image of 14 GiB with a few
# GiB of data takes the time of those few GiB, not of the whole file).
#
#   write-sd.sh [--yes] [--no-eject] IMAGE DEVICE
#
#   IMAGE   deploy/<arch>/unitotem-*.img or .img.xz (an .xz is expanded once, in tmpfs only)
#   DEVICE  whole disk, e.g. /dev/sdb or /dev/mmcblk0; every partition on it is lost
#
# At the end a removable device is flushed and ejected (--no-eject keeps it). Needs root. Refuses a device with mounted partitions, the disk holding / or /boot, and a device smaller than the image's
# partitions. Without --yes the device is shown and a (y/n) confirmation is read from the terminal.
#
# Table: the dump of the image's table, without last-lba (the backup table goes to the real end of the disk), with the same
# GUIDs, labels and start sectors; the MBR boot code is copied. Filesystems keep their UUID and label (partclone clones
# them). The expanded image lives only in tmpfs (/dev/shm); the copy is refused when it does not fit there. The last partition is not grown: DATA grows to the disk end at the first boot (docs/system/storage-and-persistence.md).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '%s %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" "$2" >&2; }
die() { log ERROR "$1"; exit 1; }

YES=0 EJECT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1; shift ;;
        --no-eject) EJECT=0; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || die "usage: $0 [--yes] [--no-eject] IMAGE DEVICE"
IMAGE=$1 DEVICE=$2

[ "$(id -u)" = 0 ] || die "must run as root"
for t in findmnt sfdisk lsblk blkid losetup partprobe partclone.extfs partclone.fat dumpe2fs e2fsck fsck.fat wipefs dd xz pv; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[ -f "$IMAGE" ] || die "image not found: $IMAGE"
[ -b "$DEVICE" ] || die "not a block device: $DEVICE"
case "$(lsblk -dno TYPE -- "$DEVICE")" in disk|loop) ;; *) die "$DEVICE is not a whole disk" ;; esac
# A card reader keeps a device per slot even when it is empty: its size is 0. The size comes from sysfs (no I/O): an ioctl on an empty slot
# (blockdev, a partition scan) can sit in the kernel for minutes and cannot be interrupted.
DEV_SECTORS=$(cat "/sys/class/block/$(basename -- "$DEVICE")/size" 2>/dev/null || echo 0)
[ "$DEV_SECTORS" -gt 0 ] || die "$DEVICE has no medium (size 0): insert the card or reseat the reader"

# --- the device must be free: nothing mounted on it, not the disk of / or /boot
if [ -n "$(lsblk -nro MOUNTPOINTS -- "$DEVICE" | tr -d ' \n')" ]; then
    die "$DEVICE has mounted partitions: unmount them first"
fi
for mp in / /boot /boot/efi; do
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null || true)
    [ -n "$src" ] || continue
    parent=$(lsblk -no PKNAME -- "$src" 2>/dev/null | head -1 || true)
    [ "/dev/${parent}" = "$DEVICE" ] && die "$DEVICE holds $mp"
done

# shellcheck source=deploy/script/image-lib.sh
source "${DIR}/deploy/script/image-lib.sh"
cleanup() { [ -z "$IMG_TMP" ] || rm -f -- "$IMG_TMP/table.sfdisk" "$IMG_TMP/partclone.log"; image_close; }
trap cleanup EXIT
image_open "$IMAGE" || die "cannot open $IMAGE"
LOOP=$IMG_LOOP
TMP=$IMG_TMP
udevadm settle --timeout=10 2>/dev/null || true

TABLE=$(sfdisk -d -- "$LOOP" | grep -v '^last-lba:' | grep -v '^device:')
printf '%s\n' "$TABLE" > "$TMP/table.sfdisk"
LABEL=$(awk -F': *' '/^label:/{print $2}' "$TMP/table.sfdisk")
[ -n "$LABEL" ] || die "the image has no partition table"

# end of the last partition, in bytes, against the device
SECT=$(awk -F': *' '/^sector-size:/{print $2}' "$TMP/table.sfdisk"); SECT=${SECT:-512}
NEED=$(awk -v s="$SECT" '/start=/ { match($0,/start= *[0-9]+/); st=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",st);
                                    match($0,/size= *[0-9]+/); sz=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",sz);
                                    e=(st+sz)*s; if (e>m) m=e } END{print m+0}' "$TMP/table.sfdisk")
HAVE=$((DEV_SECTORS * 512))
[ "$NEED" -gt 0 ] || die "cannot read the partition sizes of the image"
[ "$HAVE" -ge "$NEED" ] || die "$DEVICE is $((HAVE / 1048576)) MiB, the partitions need $((NEED / 1048576)) MiB"

if [ "$YES" != 1 ]; then
    lsblk -o NAME,SIZE,MODEL,TRAN,TYPE -- "$DEVICE" >&2
    printf 'Erase %s and write %s? (y/n) ' "$DEVICE" "$IMAGE" >&2
    read -r answer
    [ "$answer" = y ] || die "cancelled"
fi

START=$(date +%s)
log INFO "partition table ($LABEL) on $DEVICE"
wipefs -a -- "$DEVICE" >/dev/null
sfdisk --force --no-reread --quiet -- "$DEVICE" < "$TMP/table.sfdisk"
dd if="$LOOP" of="$DEVICE" bs=440 count=1 conv=notrunc status=none     # MBR boot code (BIOS GRUB, protective MBR)
partprobe "$DEVICE" 2>/dev/null || true
partx -u "$DEVICE" 2>/dev/null || true
udevadm settle --timeout=10 2>/dev/null || true

# used bytes of a filesystem (the size pv measures progress against); empty when unknown
used_bytes() {
    local dev=$1 fs=$2 o a b bs
    case "$fs" in
        ext2|ext3|ext4)
            o=$(dumpe2fs -h "$dev" 2>/dev/null || true)
            a=$(awk -F': *' '/^Block count:/{print $2}' <<<"$o"); b=$(awk -F': *' '/^Free blocks:/{print $2}' <<<"$o")
            bs=$(awk -F': *' '/^Block size:/{print $2}' <<<"$o")
            [ -n "$a" ] && [ -n "$b" ] && [ -n "$bs" ] && echo $(( (a - b) * bs )) ;;
        vfat)
            o=$(fsck.fat -n -v "$dev" 2>/dev/null || true)
            bs=$(awk '/bytes per cluster/{print $1; exit}' <<<"$o")
            a=$(sed -nE 's#.*[ ,]([0-9]+)/[0-9]+ clusters.*#\1#p' <<<"$o" | head -1)
            [ -n "$bs" ] && [ -n "$a" ] && echo $(( a * bs )) ;;
    esac
}

# partition number -> device node, for the loop (source) and the target
node_of() {
    local base c; base=/sys/class/block/$(basename -- "$1")
    for c in "$base"/*/partition; do
        [ -e "$c" ] || continue
        [ "$(cat "$c")" = "$2" ] && { echo "/dev/$(basename -- "$(dirname -- "$c")")"; return; }
    done
}
NUMS=$(sed -nE 's#^/dev/[^ ]*[^0-9]([0-9]+) *:.*#\1#p' "$TMP/table.sfdisk" | sort -n)
for n in $NUMS; do
    src=$(node_of "$LOOP" "$n"); dst=""
    for _ in $(seq 1 50); do dst=$(node_of "$DEVICE" "$n"); [ -n "$dst" ] && [ -b "$dst" ] && break; sleep 0.2; done
    { [ -b "$src" ] && [ -b "$dst" ]; } || die "partition $n: device node missing (source '$src', target '$dst')"
    fstype=$(blkid -o value -s TYPE -- "$src" 2>/dev/null || true)
    name=$(lsblk -no PARTLABEL -- "$src" 2>/dev/null | head -1)
    t0=$(date +%s)
    case "$fstype" in
        ext2|ext3|ext4) tool=partclone.extfs ;;
        vfat)           tool=partclone.fat ;;
        *)              tool=dd ;;
    esac
    log INFO "partition $n ${name:+($name) }$fstype: $tool"
    if [ "$tool" = dd ]; then
        pv -N "p$n${name:+ $name}" -s "$(blockdev --getsize64 "$src")" "$src" | dd of="$dst" bs=1M conv=fsync status=none
        st=("${PIPESTATUS[@]}")
        [ "${st[0]}" = 0 ] && [ "${st[1]}" = 0 ] || die "copy of partition $n failed"
    else
        # partclone reads the used blocks into a stream; pv shows the progress against the used bytes
        used=$(used_bytes "$src" "$fstype")
        "$tool" --clone --quiet --source "$src" --output - 2> "$TMP/partclone.log" \
            | pv -N "p$n${name:+ $name}" ${used:+-s "$used"} \
            | "$tool" --restore --quiet --source - --output "$dst" 2>> "$TMP/partclone.log"
        st=("${PIPESTATUS[@]}")
        if [ "${st[0]}" != 0 ] || [ "${st[1]}" != 0 ] || [ "${st[2]}" != 0 ]; then
            tail -n 5 -- "$TMP/partclone.log" >&2; die "$tool failed on partition $n"
        fi
    fi
    log INFO "partition $n done in $(( $(date +%s) - t0 )) s"
done
sync
partprobe "$DEVICE" 2>/dev/null || true
udevadm settle --timeout=10 2>/dev/null || true

# --- check: label and UUID of every filesystem equal the image's, ext4 and FAT are consistent
bad=0
for n in $NUMS; do
    src=$(node_of "$LOOP" "$n"); dst=$(node_of "$DEVICE" "$n")
    for k in LABEL UUID; do
        a=$(blkid -o value -s "$k" -- "$src" 2>/dev/null || true); b=$(blkid -o value -s "$k" -- "$dst" 2>/dev/null || true)
        [ "$a" = "$b" ] || { log ERROR "partition $n: $k differs ('$a' / '$b')"; bad=1; }
    done
    case "$(blkid -o value -s TYPE -- "$dst" 2>/dev/null || true)" in
        ext2|ext3|ext4) e2fsck -fn "$dst" >/dev/null 2>&1 || { log ERROR "partition $n: e2fsck reports errors"; bad=1; } ;;
        vfat)           fsck.fat -n "$dst" >/dev/null 2>&1 || { log ERROR "partition $n: fsck.fat reports errors"; bad=1; } ;;
    esac
done
[ "$bad" = 0 ] || die "verification failed"
log INFO "done in $(( $(date +%s) - START )) s: $DEVICE"
if [ "$EJECT" = 1 ] && [ "$(lsblk -dno RM -- "$DEVICE" | tr -d ' ')" = 1 ] && [ "$(lsblk -dno TYPE -- "$DEVICE")" = disk ]; then
    sync
    if command -v eject >/dev/null 2>&1 && eject -- "$DEVICE" 2>/dev/null; then log INFO "ejected $DEVICE: the card can be removed"
    else log WARN "cannot eject $DEVICE: unmount it from the desktop before removing it"; fi
fi

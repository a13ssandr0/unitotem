#!/bin/bash
# Shrinks ROOT_A of an A/B build image to its minimum: e2fsck -f, resize2fs -M, partition cut to the filesystem
# size + 16 MiB (MiB aligned), file truncated 1 MiB after the partition.
#   GPT (amd64): partition 2 is found by name, the backup GPT is moved to the new end.
#   DOS (arm64): partition 2 is found by its filesystem label; entry 2 is rewritten with sfdisk, the FIRMWARE entry
#                (bootable) is untouched, the DOS table has no backup to move.
# Idempotent: a second run changes no table entry, file size or block count; e2fsck only rewrites the ROOT_A
# superblock (check time). Used by stage3-image.sh.
#   shrink-root-image.sh IMG_FILE
set -Eeuo pipefail
IMG="${1:?usage: shrink-root-image.sh IMG_FILE}"
MIB=1048576
BIOS_GUID=21686148-6449-6E6F-744E-656564454649
LOOP=""

die() { echo "shrink-root-image: $*" >&2; exit 1; }
detach() { if [ -n "$LOOP" ]; then losetup -d "$LOOP" 2>/dev/null || true; LOOP=""; fi; }
trap detach EXIT
trap 'echo "shrink-root-image: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

[ -f "$IMG" ] || die "$IMG not found"

# Attach with partition nodes; wait (bounded) until the ROOT_A node appears.
attach() {
    local mode="$1" i
    LOOP=$(losetup --find --show --partscan $mode "$IMG") || die "losetup failed"
    for i in $(seq 50); do [ -b "${LOOP}p2" ] && return 0; sleep 0.1; done
    die "${LOOP}p2 did not appear"
}

DUMP=$(sfdisk -d "$IMG") || die "sfdisk cannot read $IMG"
TABLE=$(sed -n 's/^label: //p' <<<"$DUMP")
case "$TABLE" in
    gpt)
        # Partition 2 must be ROOT_A and the last data partition by position (the BIOS boot partition is ignored).
        info=$(sgdisk -i 2 "$IMG") || die "sgdisk cannot read partition 2"
        name=$(sed -n "s/^Partition name: '\(.*\)'$/\1/p" <<<"$info")
        [ "$name" = ROOT_A ] || die "partition 2 is '$name', expected ROOT_A"
        OLD_START=$(sed -n 's/^First sector: \([0-9]*\).*/\1/p' <<<"$info")
        OLD_END=$(sed -n 's/^Last sector: \([0-9]*\).*/\1/p' <<<"$info")
        TYPE_GUID=$(sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p' <<<"$info")
        UNIQUE_GUID=$(sed -n 's/^Partition unique GUID: //p' <<<"$info")
        ATTR=$(sed -n 's/^Attribute flags: //p' <<<"$info")
        [[ "$OLD_START" =~ ^[0-9]+$ && "$OLD_END" =~ ^[0-9]+$ && -n "$TYPE_GUID" && -n "$UNIQUE_GUID" ]] \
            || die "cannot read the geometry of partition 2"

        LAST_N=""; LAST_END=-1
        for n in $(sgdisk -p "$IMG" | awk '$1 ~ /^[0-9]+$/ {print $1}'); do
            pinfo=$(sgdisk -i "$n" "$IMG")
            ptg=$(sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p' <<<"$pinfo")
            [ "${ptg^^}" = "$BIOS_GUID" ] && continue
            pend=$(sed -n 's/^Last sector: \([0-9]*\).*/\1/p' <<<"$pinfo")
            if [ "$pend" -gt "$LAST_END" ]; then LAST_END=$pend; LAST_N=$n; fi
        done
        [ "$LAST_N" = 2 ] || die "partition 2 (ROOT_A) is not the last data partition (last is $LAST_N)"
        ;;
    dos)
        # Entry 2 (ROOT_A, checked by label after the attach below) must end last. Entries have no names.
        mapfile -t DLINES < <(grep ' : start=' <<<"$DUMP")
        [ "${#DLINES[@]}" -ge 2 ] || die "$IMG: fewer than two partitions"
        OLD_START=$(sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"${DLINES[1]}")
        OLD_SIZE=$(sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"${DLINES[1]}")
        [[ "$OLD_START" =~ ^[0-9]+$ && "$OLD_SIZE" =~ ^[0-9]+$ ]] || die "cannot read the geometry of partition 2"
        OLD_END=$((OLD_START + OLD_SIZE - 1))
        ID_BEFORE=$(sed -n 's/^label-id: //p' <<<"$DUMP")
        LAST_N=""; LAST_END=-1
        for i in "${!DLINES[@]}"; do
            s=$(sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"${DLINES[i]}")
            z=$(sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"${DLINES[i]}")
            [[ "$s" =~ ^[0-9]+$ && "$z" =~ ^[0-9]+$ ]] || die "cannot read partition $((i + 1))"
            if [ $((s + z - 1)) -gt "$LAST_END" ]; then LAST_END=$((s + z - 1)); LAST_N=$((i + 1)); fi
        done
        [ "$LAST_N" = 2 ] || die "partition 2 (ROOT_A) is not the last partition (last is $LAST_N)"
        ;;
    *) die "$IMG: partition table '$TABLE' is neither gpt nor dos" ;;
esac

# 1. Filesystem: check, shrink to the minimum, read the resulting size.
# One resize2fs -M can leave room for a further shrink (block groups and the inode table move), so it repeats
# until the block count is stable: the result is a fixed point and a second run changes nothing.
attach ""
if [ "$TABLE" = dos ]; then
    [ "$(blkid -p -s LABEL -o value "${LOOP}p2")" = ROOT_A ] || die "partition 2 is not labelled ROOT_A"
fi
PREV=""
for pass in 1 2 3 4 5 6 7 8; do
    rc=0; e2fsck -fy "${LOOP}p2" || rc=$?
    [ "$rc" -le 1 ] || die "e2fsck on ROOT_A failed (exit $rc)"
    resize2fs -M "${LOOP}p2" >/dev/null
    dump=$(dumpe2fs -h "${LOOP}p2" 2>/dev/null)
    BLOCKS=$(sed -n 's/^Block count: *//p' <<<"$dump")
    BSIZE=$(sed -n 's/^Block size: *//p' <<<"$dump")
    [[ "$BLOCKS" =~ ^[0-9]+$ && "$BSIZE" =~ ^[0-9]+$ ]] || die "cannot read the block count and size"
    [ "$BLOCKS" = "$PREV" ] && break
    PREV=$BLOCKS
done
[ "$BLOCKS" = "$PREV" ] || die "resize2fs -M does not settle on a block count"
detach

# 2. Partition: filesystem + 16 MiB, rounded up to 1 MiB. Never grown.
FS_BYTES=$((BLOCKS * BSIZE))
PART_BYTES=$(( (FS_BYTES + 16 * MIB + MIB - 1) / MIB * MIB ))
NEW_END=$((OLD_START + PART_BYTES / 512 - 1))
[ "$NEW_END" -le "$OLD_END" ] || NEW_END=$OLD_END
if [ "$NEW_END" -lt "$OLD_END" ]; then
    if [ "$TABLE" = gpt ]; then
        # 3. Partition entry rewritten with the same start, type, unique GUID, name and attributes.
        sgdisk -d 2 -n "2:${OLD_START}:${NEW_END}" -t "2:${TYPE_GUID}" -u "2:${UNIQUE_GUID}" -c 2:ROOT_A "$IMG" >/dev/null
        if [ "$ATTR" != 0000000000000000 ] && [ -n "$ATTR" ]; then
            sgdisk -A "2:=:${ATTR}" "$IMG" >/dev/null
        fi
    else
        # 3. Entry 2 rewritten with the same start and type; the table's label-id and entry 1 are kept.
        echo "start=${OLD_START}, size=$((NEW_END - OLD_START + 1)), type=83" \
            | sfdisk -q --no-reread -N 2 "$IMG" >/dev/null || die "sfdisk cannot rewrite entry 2"
    fi
    # 4. File ends 1 MiB after the partition.
    truncate -s $(( (NEW_END + 1) * 512 + MIB )) "$IMG"
    if [ "$TABLE" = gpt ]; then
        # the backup GPT is missing after the truncate: sgdisk reports it and rewrites it (checked below)
        sgdisk -e "$IMG" >/dev/null 2>&1
    fi
fi
if [ "$TABLE" = gpt ]; then
    sgdisk -v "$IMG" 2>&1 | grep -q "No problems found" || die "sgdisk -v reports problems"
else
    sfdisk -V "$IMG" >/dev/null 2>&1 || die "sfdisk -V reports problems"
fi

# 5. Verify read-only: filesystem clean and inside the partition, partition still ROOT_A.
attach "--read-only"
fsck.ext4 -fn "${LOOP}p2" >/dev/null || die "fsck.ext4 on ROOT_A is not clean"
dump=$(dumpe2fs -h "${LOOP}p2" 2>/dev/null)
BLOCKS=$(sed -n 's/^Block count: *//p' <<<"$dump")
BSIZE=$(sed -n 's/^Block size: *//p' <<<"$dump")
FS_BYTES=$((BLOCKS * BSIZE))
PART_BYTES=$(( (NEW_END - OLD_START + 1) * 512 ))
[ "$FS_BYTES" -le "$PART_BYTES" ] || die "ROOT_A filesystem (${FS_BYTES} bytes) is larger than its partition"
if [ "$TABLE" = gpt ]; then
    name=$(sgdisk -i 2 "$IMG" | sed -n "s/^Partition name: '\(.*\)'$/\1/p")
    [ "$name" = ROOT_A ] || die "partition 2 is '$name' after the shrink"
else
    [ "$(blkid -p -s LABEL -o value "${LOOP}p2")" = ROOT_A ] || die "partition 2 is not labelled ROOT_A after the shrink"
    DUMP=$(sfdisk -d "$IMG")
    [ "$(sed -n 's/^label-id: //p' <<<"$DUMP")" = "$ID_BEFORE" ] || die "the DOS label-id changed"
    mapfile -t DLINES < <(grep ' : start=' <<<"$DUMP")
    L1=${DLINES[0]}; L2=${DLINES[1]}
    [ "$(sed -nE 's/.*type= *([0-9a-fA-F]+).*/\1/p' <<<"$L1")" = c ] && grep -q 'bootable' <<<"$L1" \
        || die "partition 1 (FIRMWARE) is not type c, bootable after the shrink"
    [ "$(sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"$L2")" = "$OLD_START" ] \
        && [ "$(sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"$L2")" = $((NEW_END - OLD_START + 1)) ] \
        && [ "$(sed -nE 's/.*type= *([0-9a-fA-F]+).*/\1/p' <<<"$L2")" = 83 ] \
        || die "partition 2 entry is not start ${OLD_START} size $((NEW_END - OLD_START + 1)) type 83"
fi
detach

echo "shrink-root-image: ROOT_A fs $((FS_BYTES / MIB)) MiB, partition $((PART_BYTES / MIB)) MiB, image $(( $(stat -c %s "$IMG") / MIB )) MiB"

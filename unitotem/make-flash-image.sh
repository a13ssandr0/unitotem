#!/bin/bash
# Flash image from the finished full image: a fresh GPT listing only the partitions that are not ROOT_B / DATA
# (boot partition(s), ROOT_A, the amd64 BIOS-boot partition) with the same GUIDs, names, attributes and start
# sectors as the full image, their bytes copied unchanged, followed by 1 MiB of free space. The first boot
# completes the layout (layout_complete in unitotem/files/overlayfs-hook.sh).
#   make-flash-image.sh FULL_IMG OUT_IMG        (writes OUT_IMG, uncompressed; needs sgdisk, losetup, e2fsprogs, dosfstools)
set -Eeuo pipefail
FULL="${1:?usage: make-flash-image.sh FULL_IMG OUT_IMG}"; OUT="${2:?usage: make-flash-image.sh FULL_IMG OUT_IMG}"
[ -f "$FULL" ] || { echo "make-flash-image: $FULL not found" >&2; exit 1; }
rm -f -- "$OUT"

sgdisk -v "$FULL" 2>&1 | grep -q "No problems found" || { echo "make-flash-image: the full image's GPT is not clean" >&2; exit 1; }
DISK_GUID=$(sgdisk -p "$FULL" | sed -n 's/^Disk identifier (GUID): //p')

# Kept partitions: number|first|last|type GUID|unique GUID|name|attribute flags
KEEP=()
last_sector=0
for n in $(sgdisk -p "$FULL" | awk '$1 ~ /^[0-9]+$/ {print $1}'); do
    info=$(sgdisk -i "$n" "$FULL")
    name=$(printf '%s\n' "$info" | sed -n "s/^Partition name: '\(.*\)'$/\1/p")
    case "$name" in ROOT_B|DATA) continue ;; esac
    tg=$(printf '%s\n' "$info" | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')
    ug=$(printf '%s\n' "$info" | sed -n 's/^Partition unique GUID: //p')
    fs=$(printf '%s\n' "$info" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
    ls_=$(printf '%s\n' "$info" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
    at=$(printf '%s\n' "$info" | sed -n 's/^Attribute flags: //p')
    KEEP+=("$n|$fs|$ls_|$tg|$ug|$name|$at")
    [ "$ls_" -le "$last_sector" ] || last_sector=$ls_
done
[ "${#KEEP[@]}" -ge 2 ] || { echo "make-flash-image: fewer than two partitions kept" >&2; exit 1; }

# end of the last kept partition + 1 MiB (backup GPT inside it)
SIZE_BYTES=$(( (last_sector + 1) * 512 + 1048576 ))
truncate -s "$SIZE_BYTES" "$OUT"
args=(-U "$DISK_GUID")
for k in "${KEEP[@]}"; do
    IFS='|' read -r n fs ls_ tg ug name at <<<"$k"
    args+=(-n "$n:$fs:$ls_" -t "$n:$tg" -u "$n:$ug" -c "$n:$name")
    [ "$at" = 0000000000000000 ] || args+=(-A "$n:=:$at")
done
sgdisk "${args[@]}" "$OUT" >/dev/null
# GRUB's boot code lives in the first 440 bytes of the MBR (amd64): copied; the protective entry stays this image's own
dd if="$FULL" of="$OUT" bs=440 count=1 conv=notrunc status=none

for k in "${KEEP[@]}"; do
    IFS='|' read -r n fs ls_ tg ug name at <<<"$k"
    dd if="$FULL" of="$OUT" bs=1M iflag=skip_bytes,count_bytes oflag=seek_bytes \
       skip=$((fs * 512)) seek=$((fs * 512)) count=$(((ls_ - fs + 1) * 512)) conv=sparse,notrunc status=none
done
sync

# Verification: clean GPT, byte-identical partitions, clean filesystems
sgdisk -v "$OUT" 2>&1 | grep -q "No problems found" || { echo "make-flash-image: GPT of $OUT is not clean" >&2; exit 1; }
for k in "${KEEP[@]}"; do
    IFS='|' read -r n fs ls_ tg ug name at <<<"$k"
    cnt=$(((ls_ - fs + 1) * 512))
    a=$(dd if="$FULL" bs=1M iflag=skip_bytes,count_bytes skip=$((fs * 512)) count=$cnt status=none | sha256sum | cut -d' ' -f1)
    b=$(dd if="$OUT"  bs=1M iflag=skip_bytes,count_bytes skip=$((fs * 512)) count=$cnt status=none | sha256sum | cut -d' ' -f1)
    [ "$a" = "$b" ] || { echo "make-flash-image: partition $n ($name) differs from the full image" >&2; exit 1; }
    echo "flash image: partition $n $name identical ($cnt bytes)"
    lo=$(losetup --find --show --read-only --offset $((fs * 512)) --sizelimit "$cnt" "$OUT")
    rc=0
    case "$name" in
        ROOT_A|ROOT|BOOT) fsck.ext4 -fn "$lo" >/dev/null 2>&1 || rc=$? ;;
        EFI|FIRMWARE)     fsck.vfat -n "$lo" >/dev/null 2>&1 || rc=$? ;;
    esac
    losetup -d "$lo"
    [ "$rc" = 0 ] || { echo "make-flash-image: fsck of $name failed ($rc)" >&2; exit 1; }
done
echo "flash image: $OUT ($((SIZE_BYTES / 1048576)) MiB)"

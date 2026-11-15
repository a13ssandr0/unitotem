#!/bin/bash
# Flash image from the finished full image: the partitions that are not ROOT_B / DATA (boot partition(s), ROOT_A, the
# amd64 BIOS-boot partition), their bytes copied unchanged, followed by 1 MiB of free space. The first boot completes
# the layout (layout_complete in unitotem/files/overlayfs-hook.sh).
#   amd64 (GPT full image): fresh GPT with the same disk GUID, partition GUIDs, names, attributes and start sectors.
#   arm64 (full image with a FIRMWARE partition): DOS (MBR) table, label-id = first 8 hex digits of the disk GUID,
#         FIRMWARE type c bootable, ROOT_A type 83, same start sectors and sizes (the Pi ROM reads the MBR only).
#   make-flash-image.sh FULL_IMG OUT_IMG        (writes OUT_IMG, uncompressed; needs sgdisk, sfdisk, losetup, e2fsprogs, dosfstools)
set -Eeuo pipefail
FULL="${1:?usage: make-flash-image.sh FULL_IMG OUT_IMG}"; OUT="${2:?usage: make-flash-image.sh FULL_IMG OUT_IMG}"
[ -f "$FULL" ] || { echo "make-flash-image: $FULL not found" >&2; exit 1; }
rm -f -- "$OUT"

sgdisk -v "$FULL" 2>&1 | grep -q "No problems found" || { echo "make-flash-image: the full image's GPT is not clean" >&2; exit 1; }
DISK_GUID=$(sgdisk -p "$FULL" | sed -n 's/^Disk identifier (GUID): //p')
DUMP=$(sfdisk -d "$FULL")
if grep -q 'name="FIRMWARE"' <<<"$DUMP"; then ARCH=arm64; else ARCH=amd64; fi

# Kept partitions: number|first|last|type GUID|unique GUID|name|attribute flags (arm64: only number, first, last, name)
KEEP=()
last_sector=0
if [ "$ARCH" = arm64 ]; then
    while IFS= read -r line; do
        case "$line" in *" : start="*) ;; *) continue ;; esac
        n=$(sed -nE 's/^.*[^0-9]([0-9]+) : .*/\1/p' <<<"$line")
        name=$(sed -nE 's/.*name="([^"]*)".*/\1/p' <<<"$line")
        case "$name" in ROOT_B|DATA) continue ;; esac
        fs=$(sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"$line")
        sz=$(sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"$line")
        ls_=$((fs + sz - 1))
        KEEP+=("$n|$fs|$ls_|||$name|")
        [ "$ls_" -le "$last_sector" ] || last_sector=$ls_
    done <<<"$DUMP"
else
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
fi
[ "${#KEEP[@]}" -ge 2 ] || { echo "make-flash-image: fewer than two partitions kept" >&2; exit 1; }
mapfile -t KEEP < <(printf '%s\n' "${KEEP[@]}" | sort -t'|' -k1,1n)
if [ "$ARCH" = arm64 ]; then
    [ "${#KEEP[@]}" -le 4 ] || { echo "make-flash-image: an MBR holds four primaries, $((${#KEEP[@]})) kept" >&2; exit 1; }
    for i in "${!KEEP[@]}"; do
        IFS='|' read -r n _ <<<"${KEEP[$i]}"
        [ "$n" = $((i + 1)) ] || { echo "make-flash-image: arm64 kept partitions are not 1..N" >&2; exit 1; }
    done
fi

# end of the last kept partition + 1 MiB (backup GPT inside it)
SIZE_BYTES=$(( (last_sector + 1) * 512 + 1048576 ))
truncate -s "$SIZE_BYTES" "$OUT"
if [ "$ARCH" = arm64 ]; then
    DOS_ID=$(printf '%s' "$DISK_GUID" | tr -d '-' | cut -c1-8 | tr 'A-F' 'a-f')
    script="label: dos"$'\n'"label-id: 0x${DOS_ID}"$'\n'"unit: sectors"$'\n\n'
    for k in "${KEEP[@]}"; do
        IFS='|' read -r n fs ls_ _ _ name _ <<<"$k"
        if [ "$name" = FIRMWARE ]; then t="type=c, bootable"; else t="type=83"; fi
        script+="start=${fs}, size=$((ls_ - fs + 1)), ${t}"$'\n'
    done
    printf '%s' "$script" | sfdisk -q "$OUT" >/dev/null || { echo "make-flash-image: cannot write the DOS table" >&2; exit 1; }
else
    args=(-U "$DISK_GUID")
    for k in "${KEEP[@]}"; do
        IFS='|' read -r n fs ls_ tg ug name at <<<"$k"
        args+=(-n "$n:$fs:$ls_" -t "$n:$tg" -u "$n:$ug" -c "$n:$name")
        [ "$at" = 0000000000000000 ] || args+=(-A "$n:=:$at")
    done
    sgdisk "${args[@]}" "$OUT" >/dev/null
    # GRUB's boot code lives in the first 440 bytes of the MBR (amd64): copied; the protective entry stays this image's own
    dd if="$FULL" of="$OUT" bs=440 count=1 conv=notrunc status=none
fi

for k in "${KEEP[@]}"; do
    IFS='|' read -r n fs ls_ _ _ name _ <<<"$k"
    dd if="$FULL" of="$OUT" bs=1M iflag=skip_bytes,count_bytes oflag=seek_bytes \
       skip=$((fs * 512)) seek=$((fs * 512)) count=$(((ls_ - fs + 1) * 512)) conv=sparse,notrunc status=none
done
sync

# Verification: valid table, byte-identical partitions, clean filesystems
if [ "$ARCH" = arm64 ]; then
    sfdisk -V "$OUT" >/dev/null 2>&1 || { echo "make-flash-image: DOS table of $OUT does not verify" >&2; exit 1; }
    DUMP_OUT=$(sfdisk -d "$OUT")
    grep -qx 'label: dos' <<<"$DUMP_OUT" && grep -qx "label-id: 0x${DOS_ID}" <<<"$DUMP_OUT" \
        || { echo "make-flash-image: $OUT is not the expected DOS table" >&2; exit 1; }
    mapfile -t PL < <(grep ' : start=' <<<"$DUMP_OUT")
    [ "${#PL[@]}" = "${#KEEP[@]}" ] || { echo "make-flash-image: $OUT has ${#PL[@]} partitions, expected ${#KEEP[@]}" >&2; exit 1; }
    for i in "${!KEEP[@]}"; do
        IFS='|' read -r n fs ls_ _ _ name _ <<<"${KEEP[$i]}"
        line=${PL[$i]}
        st=$(sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"$line")
        sz=$(sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"$line")
        ty=$(sed -nE 's/.*type= *([0-9a-fA-F]+).*/\1/p' <<<"$line")
        want=83; [ "$name" = FIRMWARE ] && want=c
        if [ "$st" != "$fs" ] || [ "$sz" != $((ls_ - fs + 1)) ] || [ "$ty" != "$want" ]; then
            echo "make-flash-image: partition $n ($name) in $OUT is not start $fs size $((ls_ - fs + 1)) type $want" >&2; exit 1
        fi
        if [ "$name" = FIRMWARE ] && ! grep -q 'bootable' <<<"$line"; then
            echo "make-flash-image: FIRMWARE in $OUT is not bootable" >&2; exit 1
        fi
    done
else
    sgdisk -v "$OUT" 2>&1 | grep -q "No problems found" || { echo "make-flash-image: GPT of $OUT is not clean" >&2; exit 1; }
fi
for k in "${KEEP[@]}"; do
    IFS='|' read -r n fs ls_ _ _ name _ <<<"$k"
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
echo "flash image: $OUT ($((SIZE_BYTES / 1048576)) MiB, $ARCH)"

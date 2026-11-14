#!/bin/bash
# Reads a UniTotem disk image directly: no parts files. Sourced by remote-deploy.sh, write-sd.sh and make-preboot-image.sh; needs root
# (loop device, mount).
#
#   image_open IMAGE       a compressed image (.xz) is expanded once, sparse, into tmpfs (/dev/shm, or $UNITOTEM_TMPFS when that is
#                          tmpfs too) and refused when the data in use does not fit there; a plain image
#                          is used where it is. Then a read-only loop device with its partitions: IMG_LOOP.
#   image_close            detaches the loop device and removes what image_open wrote
#   image_node N           device node of partition N of the image
#   image_stream N         partition N on stdout as the OTA engine's restore-part reads it: `partclone.<fs> -c` (a raw copy for the
#                          BIOS boot partition) through xz
#   image_describe DIR ARCH   the descriptor of the image in DIR (a tmpfs directory, a few KiB): parts.manifest, layout.sfdisk,
#                          bootcode.bin, and the file-level tar of the boot partition (p<N>-<LABEL>.bootfs.tar.xz)
#
# Not meant to be executed directly.

IMG_TMP="" IMG_FILE="" IMG_LOOP="" IMG_MNT=""
IMG_TMPFS="${UNITOTEM_TMPFS:-/dev/shm}"

_img_err() { printf '%s ERROR %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" >&2; }

# Only tmpfs (or ramfs) takes the expanded image.
image_tmpfs_ok() {
    case "$(findmnt -no FSTYPE -T "$1" 2>/dev/null)" in tmpfs|ramfs) return 0 ;; *) return 1 ;; esac
}

image_open() {
    local image="$1" raw avail
    [ -f "$image" ] || { _img_err "image not found: $image"; return 1; }
    case "$image" in
        *.xz)
            image_tmpfs_ok "$IMG_TMPFS" || { _img_err "$IMG_TMPFS is not tmpfs: the image is expanded only in memory"; return 1; }
            raw=$(xz --robot --list -- "$image" | awk -F'\t' '$1=="totals"{print $5}')
            [ -n "$raw" ] || { _img_err "cannot read the size of $image"; return 1; }
            # The expansion is sparse: only the data in use takes memory, so the free space is not compared with the uncompressed size; a
            # full tmpfs stops the copy (ENOSPC) and the image is refused below.
            avail=$(df -B1 --output=avail "$IMG_TMPFS" | tail -n 1 | tr -d ' ')
            IMG_TMP=$(mktemp -d "$IMG_TMPFS/unitotem-image.XXXXXX")
            IMG_FILE="$IMG_TMP/image.img"
            echo "$(date +%Y-%m-%dT%H:%M:%S) INFO expanding $(basename -- "$image") into $IMG_TMPFS" >&2
            xz -dc -T0 -- "$image" | pv -N expand -s "$raw" | dd of="$IMG_FILE" bs=4M conv=sparse status=none
            local st=("${PIPESTATUS[@]}")
            [ "${st[0]}" = 0 ] && [ "${st[2]}" = 0 ] || { _img_err "the expanded image does not fit in $IMG_TMPFS ($((avail / 1048576)) MiB free) or $image is damaged"; image_close; return 1; }
            ;;
        *)
            IMG_TMP=$(mktemp -d "$IMG_TMPFS/unitotem-image.XXXXXX")
            IMG_FILE="$image"
            ;;
    esac
    IMG_LOOP=$(losetup --find --show --read-only --partscan -- "$IMG_FILE") || { _img_err "cannot attach the image"; image_close; return 1; }
    udevadm settle --timeout=10 2>/dev/null || true
    return 0
}

image_close() {
    [ -z "$IMG_MNT" ] || { umount "$IMG_MNT" 2>/dev/null || true; rmdir -- "$IMG_MNT" 2>/dev/null || true; IMG_MNT=""; }
    [ -z "$IMG_LOOP" ] || { losetup -d "$IMG_LOOP" 2>/dev/null || true; IMG_LOOP=""; }
    if [ -n "$IMG_TMP" ]; then
        rm -f -- "$IMG_TMP/image.img"
        rmdir -- "$IMG_TMP" 2>/dev/null || true
        IMG_TMP=""
    fi
}

image_node() {   # $1 partition number
    local base c; base=/sys/class/block/$(basename -- "$IMG_LOOP")
    for c in "$base"/*/partition; do
        [ -e "$c" ] || continue
        [ "$(cat "$c")" = "$1" ] && { echo "/dev/$(basename -- "$(dirname -- "$c")")"; return 0; }
    done
    return 1
}

# Action and cloner per partition label. EFI and FIRMWARE are copied file by file (never partclone'd: a restore must not
# clobber the resident fallback on the same partition); DATA is kept or made new, never streamed; ROOT_B ships empty.
_img_action() {
    case "$1" in
        EFI|FIRMWARE) echo filecopy ;;
        DATA)         echo data ;;
        BOOT|ROOT|ROOT_A) echo restore ;;
        ROOT_B)       echo format ;;
        BIOS)         echo raw ;;
        *)            echo skip ;;
    esac
}
_img_cloner() {
    case "$1" in
        EFI|FIRMWARE) echo fat ;;
        BOOT|ROOT|ROOT_A) echo extfs ;;
        BIOS)         echo dd ;;
        *)            echo "" ;;
    esac
}

# ext4 used bytes: (blocks - free blocks) * block size
_img_ext4_used() {
    local o t f b
    o=$(dumpe2fs -h "$1" 2>/dev/null) || { echo 0; return; }
    t=$(awk -F': *' '/^Block count:/{print $2}' <<<"$o"); f=$(awk -F': *' '/^Free blocks:/{print $2}' <<<"$o")
    b=$(awk -F': *' '/^Block size:/{print $2}' <<<"$o")
    [ -n "$t" ] && [ -n "$f" ] && [ -n "$b" ] && echo $(( (t - f) * b )) || echo 0
}

# Label of a partition of the image; the GPT BIOS boot partition (no filesystem) is BIOS.
_img_label() {   # $1 node, $2 number
    local l; l=$(blkid -s LABEL -o value "$1" 2>/dev/null || true)
    if [ -z "$(_img_cloner "$l")" ] && [ "$(sfdisk --part-type "$IMG_LOOP" "$2" 2>/dev/null | tr 'A-F' 'a-f')" = "21686148-6449-6e6f-744e-656564454649" ]; then l=BIOS; fi
    echo "$l"
}

image_describe() {   # $1 directory, $2 arch
    local out="$1" arch="$2" n dev label fstype action cloner used sectors start nparts=0 data_part="" bootfs_part="" layout=1 total_used=0 min_disk
    local raw_size; raw_size=$(blockdev --getsize64 "$IMG_LOOP")
    mkdir -p -- "$out"
    sfdisk --dump "$IMG_LOOP" > "$out/layout.sfdisk"
    dd if="$IMG_LOOP" of="$out/bootcode.bin" bs=440 count=1 status=none
    : > "$out/parts.manifest.partial"
    for n in $(sed -nE 's#^/dev/[^ ]*[^0-9]([0-9]+) *:.*#\1#p' "$out/layout.sfdisk" | sort -n); do
        dev=$(image_node "$n") || continue
        label=$(_img_label "$dev" "$n"); action=$(_img_action "$label")
        [ "$action" != skip ] || continue
        cloner=$(_img_cloner "$label"); fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
        nparts=$((nparts + 1))
        start=$(cat "/sys/class/block/$(basename -- "$dev")/start" 2>/dev/null || echo 0); sectors=$(blockdev --getsz "$dev")
        case "$label" in DATA) data_part=$n ;; ROOT_A) layout=2 ;; EFI|FIRMWARE) bootfs_part=$n ;; esac
        {
            echo "UNITOTEM_PART=$n"; echo "UNITOTEM_PART_LABEL=${label:-none}"; echo "UNITOTEM_PART_FSTYPE=${fstype:-none}"
            echo "UNITOTEM_PART_CLONER=${cloner:-none}"; echo "UNITOTEM_PART_ACTION=$action"
            echo "UNITOTEM_PART_START=$start"; echo "UNITOTEM_PART_SECTORS=$sectors"
            # FAT serial of the boot partition: GRUB's images find their config by it, a deploy that reformats it gives it back.
            [ "$action" != filecopy ] || echo "UNITOTEM_PART_VOLID=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
        } >> "$out/parts.manifest.partial"
        case "$action" in
            data|format) echo "" >> "$out/parts.manifest.partial"; continue ;;
            filecopy)
                local tarball="p${n}-${label}.bootfs.tar.xz"
                IMG_MNT=$(mktemp -d "$IMG_TMPFS/unitotem-mnt.XXXXXX")
                mount -t "${fstype:-vfat}" -o ro "$dev" "$IMG_MNT"
                tar -C "$IMG_MNT" -cf - . | xz -T0 -3 --check=sha256 > "$out/$tarball"
                umount "$IMG_MNT"; rmdir -- "$IMG_MNT"; IMG_MNT=""
                { echo "UNITOTEM_PART_STREAM_FILE=$tarball"; echo "UNITOTEM_PART_COMP=xz"; echo ""; } >> "$out/parts.manifest.partial"
                continue ;;
        esac
        used=$((sectors * 512)); [ "$cloner" != extfs ] || used=$(_img_ext4_used "$dev")
        total_used=$((total_used + used))
        { echo "UNITOTEM_PART_USED_BYTES=$used"; echo "UNITOTEM_PART_COMP=xz"; echo ""; } >> "$out/parts.manifest.partial"
    done
    min_disk=$raw_size
    if [ -n "$data_part" ]; then
        min_disk=$(( ($(cat "/sys/class/block/$(basename -- "$(image_node "$data_part")")/start") + 2048 + 33) * 512 ))
    fi
    {
        echo "UNITOTEM_LAYOUT=$layout"; echo "UNITOTEM_ARCH=$arch"; echo "UNITOTEM_RAW_SIZE=$raw_size"
        echo "UNITOTEM_MIN_DISK_BYTES=$min_disk"; echo "UNITOTEM_TABLE=gpt"; echo "UNITOTEM_SECTOR_SIZE=512"
        echo "UNITOTEM_NPARTS=$nparts"; echo "UNITOTEM_DATA_PART=${data_part:-0}"; echo "UNITOTEM_BOOTFS_PART=${bootfs_part:-1}"
        echo "UNITOTEM_TOTAL_USED_BYTES=$total_used"; echo ""
        cat "$out/parts.manifest.partial"
    } > "$out/parts.manifest"
    rm -f -- "$out/parts.manifest.partial"
}

# The table of the descriptor as an MBR (a GPT image for a board whose ROM reads MBR only): same start and size of every partition, type c
# for the FAT firmware partition, 83 for the others, disk id taken from the GPT disk GUID; the MBR boot code of a GPT disk is empty, so
# bootcode.bin is dropped. Four primaries at most.
image_table_dos() {   # $1 descriptor directory
    local d="$1" f="$1/layout.sfdisk" id n=0 line st sz name t out
    [ "$(awk -F': *' '/^label:/{print $2}' "$f")" = gpt ] || return 0
    id=$(awk -F': *' '/^label-id:/{print $2}' "$f" | tr -d '-' | cut -c1-8 | tr 'A-F' 'a-f')
    out="label: dos"$'\n'"label-id: 0x${id}"$'\n'"unit: sectors"$'\n\n'
    while IFS= read -r line; do
        case "$line" in /dev/*" : "*) ;; *) continue ;; esac
        n=$((n + 1)); [ "$n" -le 4 ] || { _img_err "an MBR holds four primary partitions, the image has more"; return 1; }
        st=$(sed -nE 's/.*start= *([0-9]+),.*/\1/p' <<<"$line"); sz=$(sed -nE 's/.*size= *([0-9]+),.*/\1/p' <<<"$line")
        name=$(sed -nE 's/.*name="([^"]*)".*/\1/p' <<<"$line")
        case "$name" in FIRMWARE|EFI) t=c ;; *) t=83 ;; esac
        out+="${line%% : *} : start=${st}, size=${sz}, type=${t}"$'\n'
    done < "$f"
    printf '%s' "$out" > "$f"
    rm -f -- "$d/bootcode.bin"
}

# One partition on stdout. extfs and fat: partclone's stream; dd: the raw partition. Compressed with xz (the engine's default
# decoder), quickly: the transfer is the limit, not the ratio.
image_stream() {   # $1 partition number
    local n="$1" dev label cloner
    dev=$(image_node "$n") || { _img_err "no partition $n in the image"; return 1; }
    label=$(_img_label "$dev" "$n"); cloner=$(_img_cloner "$label")
    case "$cloner" in
        dd)       dd if="$dev" bs=512 status=none | xz -T0 -1 --check=sha256 ;;
        extfs|fat) "partclone.${cloner}" -c -s "$dev" -o - -F -B 2>/dev/null | xz -T0 -1 --check=sha256 ;;
        *)        _img_err "partition $n ($label) has no stream"; return 1 ;;
    esac
}

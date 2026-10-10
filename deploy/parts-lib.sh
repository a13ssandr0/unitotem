#!/bin/bash
# Parts-set generator library: make_parts() clones every restore-relevant
# partition of an already-attached loop device into
# deploy/$ARCH/<setname>.parts/. Callable from deploy/make-parts-image.sh
# (in-container, from a scratch image file) or from kiosk/stage3-image.sh's
# optional MAKE_PARTS hook (against the loop device it already has attached
# while building the image) - one implementation, two call sites, per the
# OTA redesign plan.
#
# Not meant to be executed directly.
set -euo pipefail

# Filesystem/cloner/action per partition LABEL. FIRMWARE/EFI are file-level
# only (never partclone'd - see the plan's partition layout section: doing
# so would risk clobbering the resident fallback kernel+initrd a real
# restore must never touch), DATA is never streamed at all (24 KiB used on
# a pristine image - always preserved or freshly mkfs'd instead).
parts_action_for_label() {
    case "$1" in
        EFI|FIRMWARE) echo "filecopy" ;;
        DATA)         echo "data" ;;
        BOOT|ROOT|ROOT_A) echo "restore" ;;
        ROOT_B)       echo "format" ;;     # A/B: the inactive slot ships empty, labelled
        BIOS)         echo "raw" ;;
        *)            echo "skip" ;;
    esac
}

parts_cloner_for_label() {
    case "$1" in
        EFI|FIRMWARE) echo "fat" ;;
        BOOT|ROOT|ROOT_A) echo "extfs" ;;
        BIOS)         echo "dd" ;;
        *)            echo "" ;;
    esac
}

# ext4 used bytes via dumpe2fs - block count minus free blocks, times block
# size. Used both to size the parts-set manifest (_PART_USED_BYTES) and, on
# the restore side, to decide whether partclone.restore -C is safe for a
# smaller-than-recorded target partition (see the plan's partclone risk
# section for why -C is the right tool here, used deliberately rather than
# avoided outright).
ext4_used_bytes() {
    local dev="$1" total free bs
    total=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F': *' '/^Block count:/{print $2}')
    free=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F': *' '/^Free blocks:/{print $2}')
    bs=$(dumpe2fs -h "$dev" 2>/dev/null | awk -F': *' '/^Block size:/{print $2}')
    [ -n "$total" ] && [ -n "$free" ] && [ -n "$bs" ] || { echo 0; return; }
    echo $(( (total - free) * bs ))
}

# make_parts <loop_device> <out_dir> <arch> <set_name> <source_image_xz>
make_parts() {
    local loop="$1" outdir="$2" arch="$3" setname="$4" srcimg="$5"
    mkdir -p "$outdir"

    partprobe "$loop" 2>/dev/null || true
    partx -u "$loop" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true

    local disk_sectors; disk_sectors=$(blockdev --getsz "$loop")
    local raw_size=$((disk_sectors * 512))

    sfdisk --dump "$loop" > "$outdir/layout.sfdisk"
    dd if="$loop" of="$outdir/bootcode.bin" bs=440 count=1 2>/dev/null

    local table_sha256; table_sha256=$(sha256sum "$outdir/layout.sfdisk" | cut -d' ' -f1)
    local bootcode_sha256; bootcode_sha256=$(sha256sum "$outdir/bootcode.bin" | cut -d' ' -f1)

    local nparts=0 data_part="" has_esp=0 bootfs_part="" total_used=0 layout=1
    local part_blocks=()

    local n dev label fstype ptype action cloner used stream stream_bytes stream_sha256
    for n in $(sfdisk -J "$loop" 2>/dev/null | grep -oE '"node": *"[^"]+"' | sed -E 's#.*p?([0-9]+)"$#\1#' | sort -un); do
        dev=$(pdev_target_local "$loop" "$n")
        [ -b "$dev" ] || continue
        label=$(blkid -s LABEL -o value "$dev" 2>/dev/null || echo "")
        fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || echo "")
        ptype=$(sfdisk --part-type "$loop" "$n" 2>/dev/null || echo "")

        action=$(parts_action_for_label "$label")
        if [ "$action" = skip ] && [ "${ptype,,}" = "ef02" ]; then
            label=BIOS; action=raw
        fi
        [ "$action" != skip ] || continue

        cloner=$(parts_cloner_for_label "$label")
        nparts=$((nparts + 1))

        local start sectors
        start=$(cat "/sys/class/block/$(basename "$loop")$( [[ "$loop" =~ (nvme|mmcblk|loop) ]] && echo p )${n}/start" 2>/dev/null || echo 0)
        sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)

        case "$label" in
            DATA) data_part="$n" ;;
            ROOT_A) layout=2 ;;
            EFI)  has_esp=1; bootfs_part="$n" ;;
            FIRMWARE) bootfs_part="$n" ;;
        esac

        {
            echo "UNITOTEM_PART=$n"
            echo "UNITOTEM_PART_LABEL=${label:-none}"
            echo "UNITOTEM_PART_FSTYPE=${fstype:-none}"
            echo "UNITOTEM_PART_CLONER=${cloner:-none}"
            echo "UNITOTEM_PART_ACTION=$action"
            echo "UNITOTEM_PART_START=$start"
            echo "UNITOTEM_PART_SECTORS=$sectors"
            # FAT serial of the boot partition: GRUB's images find their config by it, so a deploy that
            # reformats the partition has to give it back.
            if [ "$action" = filecopy ]; then
                echo "UNITOTEM_PART_VOLID=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
            fi
        } >> "$outdir/parts.manifest.partial"

        case "$action" in
            data|format)
                echo "" >> "$outdir/parts.manifest.partial"
                continue
                ;;
            filecopy)
                # EFI/FIRMWARE is never partclone'd (a real restore must
                # never risk clobbering the resident fallback recovery
                # files living on the same partition - see the plan's
                # partition layout section), but a *new* target still needs
                # its static content (EFI/BOOT/BOOTX64.EFI on amd64;
                # bootcode.bin/start*.elf/fixup*.dat/overlays on arm64) from
                # somewhere. Capture it as a plain tar - deploy/ota-engine.sh's
                # populate-bootfs subcommand extracts it with an explicit
                # --exclude for anything recovery-owned, so applying it to
                # an already-prepared target can never touch those files.
                stream="p${n}-${label:-part${n}}.bootfs.tar.xz"
                log_parts "Genero ${stream} (contenuto file-level di ${label})..."
                mkdir -p /tmp/bootfs-src
                mount -t "${fstype:-vfat}" -o ro "$dev" /tmp/bootfs-src
                tar -C /tmp/bootfs-src -cf - . | xz -T0 -9 --check=sha256 > "$outdir/$stream"
                umount /tmp/bootfs-src
                stream_bytes=$(stat -c%s "$outdir/$stream")
                stream_sha256=$(sha256sum "$outdir/$stream" | cut -d' ' -f1)
                {
                    echo "UNITOTEM_PART_STREAM_FILE=$stream"
                    echo "UNITOTEM_PART_STREAM_BYTES=$stream_bytes"
                    echo "UNITOTEM_PART_STREAM_SHA256=$stream_sha256"
                    echo "UNITOTEM_PART_COMP=xz"
                    echo ""
                } >> "$outdir/parts.manifest.partial"
                continue
                ;;
        esac

        used=$((sectors * 512))
        [ "$cloner" = extfs ] && used=$(ext4_used_bytes "$dev")
        total_used=$((total_used + used))

        stream="p${n}-${label:-part${n}}.${fstype:-raw}.pc.xz"
        log_parts "Genero ${stream} (cloner=${cloner}, partizione ${n})..."
        "partclone.${cloner}" -c -s "$dev" -o - -F -B 2>/dev/null \
            | xz -T0 -9 --check=sha256 > "$outdir/$stream" \
            || { echo "partclone.${cloner} su $dev fallito" >&2; return 1; }

        stream_bytes=$(stat -c%s "$outdir/$stream")
        stream_sha256=$(sha256sum "$outdir/$stream" | cut -d' ' -f1)

        {
            echo "UNITOTEM_PART_USED_BYTES=$used"
            echo "UNITOTEM_PART_STREAM_FILE=$stream"
            echo "UNITOTEM_PART_STREAM_BYTES=$stream_bytes"
            echo "UNITOTEM_PART_STREAM_SHA256=$stream_sha256"
            echo "UNITOTEM_PART_COMP=xz"
            echo ""
        } >> "$outdir/parts.manifest.partial"
    done

    local pc_ver pc_fmt
    pc_ver=$(partclone.restore -v 2>&1 | head -1 | awk '{print $2}')
    pc_fmt=$(command -v partclone.info >/dev/null 2>&1 && partclone.info -v 2>&1 | head -1 | awk '{print $2}' || echo "$pc_ver")

    local min_disk=$raw_size
    [ -n "$data_part" ] && {
        local data_dev; data_dev=$(pdev_target_local "$loop" "$data_part")
        local data_start; data_start=$(cat "/sys/class/block/$(basename "$loop")$( [[ "$loop" =~ (nvme|mmcblk|loop) ]] && echo p )${data_part}/start" 2>/dev/null || echo 0)
        min_disk=$(( (data_start + 2048 + 33) * 512 ))
    }

    {
        echo "UNITOTEM_PARTS_PROTO=1"
        echo "UNITOTEM_LAYOUT=$layout"
        echo "UNITOTEM_ARCH=$arch"
        echo "UNITOTEM_SET_NAME=$setname"
        echo "UNITOTEM_SOURCE_IMAGE=$(basename "$srcimg")"
        echo "UNITOTEM_SOURCE_SHA256=$(sha256sum "$srcimg" | cut -d' ' -f1)"
        echo "UNITOTEM_RAW_SIZE=$raw_size"
        echo "UNITOTEM_MIN_DISK_BYTES=$min_disk"
        echo "UNITOTEM_TABLE=gpt"
        echo "UNITOTEM_TABLE_FILE=layout.sfdisk"
        echo "UNITOTEM_TABLE_SHA256=$table_sha256"
        echo "UNITOTEM_SECTOR_SIZE=512"
        echo "UNITOTEM_BOOTCODE_FILE=bootcode.bin"
        echo "UNITOTEM_BOOTCODE_SHA256=$bootcode_sha256"
        echo "UNITOTEM_BOOTCODE_BYTES=440"
        echo "UNITOTEM_NPARTS=$nparts"
        echo "UNITOTEM_DATA_PART=${data_part:-0}"
        echo "UNITOTEM_HAS_ESP=$has_esp"
        echo "UNITOTEM_BOOTFS_PART=${bootfs_part:-1}"
        echo "UNITOTEM_PARTCLONE_VERSION=$pc_ver"
        echo "UNITOTEM_PARTCLONE_IMG_FORMAT=$pc_fmt"
        echo "UNITOTEM_TOTAL_USED_BYTES=$total_used"
        echo ""
        cat "$outdir/parts.manifest.partial"
    } > "$outdir/parts.manifest"
    rm -f "$outdir/parts.manifest.partial"

    ( cd "$outdir" && sha256sum -- *.xz layout.sfdisk bootcode.bin > SHA256SUMS )

    log_parts "Parts set completo: $outdir (${nparts} partizioni, $(bytes_human_local "$total_used") usati)"
}

pdev_target_local() {
    case "$1" in
        *nvme*|*mmcblk*|*loop*) echo "${1}p${2}" ;;
        *)                       echo "${1}${2}" ;;
    esac
}

bytes_human_local() {
    awk -v b="$1" 'BEGIN{split("B K M G T",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};printf "%.1f%s",b,u[i]}'
}

log_parts() { echo ">>> $*"; }

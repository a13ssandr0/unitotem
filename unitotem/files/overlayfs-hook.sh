#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }

# grow_data DEV: grow the DATA partition into the free space after it, up to the disk end, and its ext4 to
# fill the partition. Offline (DATA unmounted), idempotent: every decision is derived from the disk (sysfs
# sizes, partition table, filesystem superblock), no flag file. Each step leaves a consistent disk:
#   1. sgdisk -e      moves the backup GPT to the disk end (valid table before and after);
#   2. sfdisk -N      rewrites the entry of DATA only (type, GUID, name, attributes kept) in one table write;
#   3. partx -u       tells the kernel the new size of that one partition (others, e.g. the mounted root, untouched);
#   4. e2fsck -f + resize2fs   grows the filesystem. A cut after 2 or 3 is finished by the next boot (the
#      filesystem is smaller than its partition); a cut inside resize2fs leaves metadata that one e2fsck -fy
#      (only in this state) repairs before the growth resumes.
# Acts only when DATA is the last partition by start sector, the disk is GPT, DATA is ext4 and at least 64 MiB
# are free after it. Never moves or removes another partition. Any failure logs one line and returns 0.
GROW_MIN_FREE=131072   # sectors (64 MiB)
GROW_MIN_FS_GAP=65536  # sectors (32 MiB): filesystem this much smaller than its partition is grown
grow_data() {
    gd_dev=$1
    for gd_t in sgdisk sfdisk partx resize2fs e2fsck dumpe2fs blkid readlink; do
        command -v "$gd_t" >/dev/null 2>&1 || return 0
    done
    gd_sys=/sys/class/block/${gd_dev##*/}
    [ -r "$gd_sys/partition" ] || return 0
    gd_num=$(cat "$gd_sys/partition") || return 0
    gd_real=$(readlink -f "$gd_sys") || return 0
    gd_par=${gd_real%/*}
    gd_disk=${gd_par##*/}
    gd_ddev=/dev/$gd_disk
    [ -r "/sys/block/$gd_disk/size" ] || return 0
    gd_dsz=$(cat "/sys/block/$gd_disk/size")
    gd_start=$(cat "$gd_sys/start")
    gd_psz=$(cat "$gd_sys/size")
    gd_end=$((gd_start + gd_psz))

    [ "$(blkid -s TYPE -o value "$gd_dev" 2>/dev/null)" = ext4 ] || { log_warning_msg "grow: DATA is not ext4, skipping"; return 0; }
    [ "$(blkid -p -s PTTYPE -o value "$gd_ddev" 2>/dev/null)" = gpt ] || { log_warning_msg "grow: $gd_disk is not GPT, skipping"; return 0; }
    for gd_p in "$gd_par"/*/start; do
        [ -r "$gd_p" ] || continue
        [ "$(cat "$gd_p")" -gt "$gd_start" ] && { log_warning_msg "grow: DATA is not the last partition, skipping"; return 0; }
    done

    # 1-3: the partition. The 33 sectors before the disk end hold the backup GPT.
    gd_free=$((gd_dsz - 34 - gd_end))
    if [ "$gd_free" -ge "$GROW_MIN_FREE" ]; then
        sgdisk -e "$gd_ddev" >/dev/null 2>&1 || { log_warning_msg "grow: sgdisk -e failed, skipping"; return 0; }
        echo ", +" | sfdisk --no-reread --no-tell-kernel --wipe never --wipe-partitions never -q -N "$gd_num" "$gd_ddev" >/dev/null 2>&1 \
            || { log_warning_msg "grow: partition table write failed, skipping"; return 0; }
        sgdisk -v "$gd_ddev" 2>&1 | grep -q "No problems found" \
            || { log_warning_msg "grow: GPT check failed after the write, skipping"; return 0; }
        partx -u --nr "$gd_num" "$gd_ddev" >/dev/null 2>&1 || true
        gd_psz=$(cat "$gd_sys/size")
        if [ "$((gd_start + gd_psz))" -le "$gd_end" ]; then
            log_warning_msg "grow: kernel did not take the new partition size, skipping"
            return 0
        fi
    fi

    # 4: the filesystem, when smaller than its partition.
    gd_info=$(dumpe2fs -h "$gd_dev" 2>/dev/null) || { log_warning_msg "grow: cannot read the DATA superblock"; return 0; }
    gd_bc=$(echo "$gd_info" | sed -n 's/^Block count: *//p')
    gd_bs=$(echo "$gd_info" | sed -n 's/^Block size: *//p')
    [ -n "$gd_bc" ] && [ -n "$gd_bs" ] || return 0
    gd_fs=$((gd_bc * gd_bs / 512))
    [ $((gd_psz - gd_fs)) -ge "$GROW_MIN_FS_GAP" ] || return 0
    e2fsck -fp "$gd_dev" >/dev/null 2>&1
    gd_rc=$?
    if [ "$gd_rc" -gt 1 ]; then
        # Reached only when the filesystem is smaller than its partition, i.e. a growth is pending: a resize2fs cut by
        # a power loss leaves metadata (resize inode, bitmaps) that e2fsck repairs; -p refuses it (exit 4). One -fy.
        e2fsck -fy "$gd_dev" >/dev/null 2>&1
        gd_rc=$?
        [ "$gd_rc" -le 1 ] || { log_warning_msg "grow: e2fsck returned ${gd_rc}, filesystem not grown"; return 0; }
        log_success_msg "grow: repaired DATA after an interrupted resize"
    fi
    resize2fs "$gd_dev" >/dev/null 2>&1 || { log_warning_msg "grow: resize2fs failed"; return 0; }
    log_success_msg "grow: DATA grown to $((gd_psz / 2048)) MiB"
    return 0
}
# layout_complete: a minimal image carries only the boot partition(s) and ROOT_A. On the first boot create ROOT_B (same
# size as stage3's slots) and DATA (rest of the disk) in the free space after ROOT_A. State is derived from the disk
# on every boot, no flag file. GPT disks:
#   - neither ROOT_B nor DATA in the GPT, ROOT_A the last partition, >= 5 GiB + 256 MiB free after it:
#       sgdisk -e (valid backup GPT at the disk end), zero the first MiB of both new areas (stale signatures of a
#       reused card), then ONE sgdisk write adds both entries, each flagged "pending" (GPT attribute bit 48);
#   - partx -a tells the kernel about the two new partitions only (ROOT_A, mounted, is not touched);
#   - every partition flagged pending is formatted (ROOT_B: ext4 label ROOT_B, the empty slot that unitotem-update
#     repair fills; DATA: ext4 label DATA, as stage3), then its flag is cleared.
# A cut before the table write changes nothing; a cut after it leaves flagged partitions that the next boot formats
# (only flagged partitions are ever formatted: a damaged filesystem is never reformatted). Never touches ROOT_A or the
# boot partition. Any failure logs one line and returns 0.
# DOS (MBR) disks: layout_mbr, the same steps with primaries only; the pending flag is the MBR type (da ROOT_B,
# db DATA). Power cuts, per step: before the table write nothing changes; after it, the next boot finds the da/db
# partitions and formats them, DATA first; a cut after mke2fs and before the type change leaves the still-flagged
# fresh (empty) filesystem, which the next boot formats again; after the type change the partition is done.
LAYOUT_SLOT_SECTORS=10485760        # ROOT_SLOT_SIZE 5G, as stage3
LAYOUT_MIN_FREE=11010048            # slot + 256 MiB for DATA
LAYOUT_LINUX_FS=8300
layout_complete() {
    for lc_t in sgdisk sfdisk partx mke2fs blkid readlink dd; do
        command -v "$lc_t" >/dev/null 2>&1 || return 0
    done
    lc_a=$(blkid -L ROOT_A 2>/dev/null) || return 0
    lc_sys=/sys/class/block/${lc_a##*/}
    [ -r "$lc_sys/partition" ] || return 0
    lc_real=$(readlink -f "$lc_sys") || return 0
    lc_par=${lc_real%/*}
    lc_disk=${lc_par##*/}
    lc_ddev=/dev/$lc_disk
    lc_pt=$(blkid -p -s PTTYPE -o value "$lc_ddev" 2>/dev/null)
    if [ "$lc_pt" = dos ]; then
        layout_mbr "$lc_ddev" "$lc_sys" "$lc_par"
        return 0
    fi
    [ "$lc_pt" = gpt ] || return 0
    lc_dump=$(sfdisk -d "$lc_ddev" 2>/dev/null) || return 0

    lc_hasb=no; lc_hasd=no
    echo "$lc_dump" | grep -q 'name="ROOT_B"' && lc_hasb=yes
    echo "$lc_dump" | grep -q 'name="DATA"' && lc_hasd=yes

    if [ "$lc_hasb" = no ] && [ "$lc_hasd" = no ]; then
        lc_start=$(cat "$lc_sys/start"); lc_size=$(cat "$lc_sys/size")
        lc_dsz=$(cat "/sys/block/$lc_disk/size")
        for lc_p in "$lc_par"/*/start; do
            [ -r "$lc_p" ] || continue
            [ "$(cat "$lc_p")" -gt "$lc_start" ] && return 0     # ROOT_A is not the last partition: not a minimal image
        done
        lc_bs=$(( (lc_start + lc_size + 2047) / 2048 * 2048 ))   # 1 MiB aligned
        lc_ds=$((lc_bs + LAYOUT_SLOT_SECTORS))
        lc_last=$((lc_dsz - 34))                                 # last usable sector (backup GPT: 33 sectors)
        [ $((lc_last - lc_bs)) -ge "$LAYOUT_MIN_FREE" ] || { log_warning_msg "layout: not enough free space for ROOT_B and DATA, skipping"; return 0; }
        sgdisk -e "$lc_ddev" >/dev/null 2>&1 || { log_warning_msg "layout: sgdisk -e failed, skipping"; return 0; }
        dd if=/dev/zero of="$lc_ddev" bs=512 seek="$lc_bs" count=2048 conv=notrunc >/dev/null 2>&1 \
            && dd if=/dev/zero of="$lc_ddev" bs=512 seek="$lc_ds" count=2048 conv=notrunc >/dev/null 2>&1 \
            || { log_warning_msg "layout: cannot clear the new areas, skipping"; return 0; }
        sgdisk -n "3:${lc_bs}:$((lc_ds - 1))" -t "3:${LAYOUT_LINUX_FS}" -c 3:ROOT_B -A 3:set:48 \
               -n "4:${lc_ds}:${lc_last}" -t "4:${LAYOUT_LINUX_FS}" -c 4:DATA -A 4:set:48 "$lc_ddev" >/dev/null 2>&1 \
            || { log_warning_msg "layout: partition table write failed, skipping"; return 0; }
        sgdisk -v "$lc_ddev" 2>&1 | grep -q "No problems found" \
            || { log_warning_msg "layout: GPT check failed after the write"; return 0; }
        lc_dump=$(sfdisk -d "$lc_ddev" 2>/dev/null) || return 0
    fi

    # Flagged partitions: make the kernel know them, format them, clear the flag.
    lc_did=""
    for lc_name in ROOT_B DATA; do
        lc_line=$(echo "$lc_dump" | grep "name=\"$lc_name\"" | grep 'GUID:48' | head -n 1)
        [ -n "$lc_line" ] || continue
        lc_dev=${lc_line%% :*}
        lc_num=$(echo "$lc_dev" | sed 's/.*[^0-9]//')
        [ -b "$lc_dev" ] || { partx -a --nr "$lc_num" "$lc_ddev" >/dev/null 2>&1; udevadm settle --timeout=2 2>/dev/null || true; }
        [ -b "$lc_dev" ] || { log_warning_msg "layout: kernel did not take $lc_name, skipping"; return 0; }
        mke2fs -t ext4 -b 4096 -F -q -L "$lc_name" "$lc_dev" >/dev/null 2>&1 \
            || { log_warning_msg "layout: mke2fs $lc_name failed"; return 0; }
        sgdisk -A "${lc_num}:clear:48" "$lc_ddev" >/dev/null 2>&1 \
            || { log_warning_msg "layout: cannot clear the flag of $lc_name"; return 0; }
        lc_did="$lc_did $lc_name"
    done
    [ -z "$lc_did" ] || log_success_msg "layout: created${lc_did}"
    return 0
}
# layout_mbr DISK SYSDIR PARDIR: the DOS (MBR) variant of layout_complete, primaries only. Creation needs ROOT_A the
# last partition, partitions 1..ROOT_A exactly, no extended partition and a free primary slot. ROOT_B (size of ROOT_A)
# and DATA are written in one sfdisk --append when the space allows, else DATA alone (it becomes the next primary).
# The table is never rewritten: --append keeps the disk label-id, --no-reread keeps the kernel away from a mounted root.
LAYOUT_MBR_MIN_FREE=524288          # 256 MiB, sectors
LAYOUT_MBR_MAX_SECTORS=4294967295   # MBR addresses 2 TiB
layout_mbr() {
    lc_ddev=$1; lc_sys=$2; lc_par=$3
    lc_dump=$(sfdisk -d "$lc_ddev" 2>/dev/null) || return 0
    if ! echo "$lc_dump" | grep -Eq 'type=(da|db)(,|$)'; then
        lc_start=$(cat "$lc_sys/start"); lc_size=$(cat "$lc_sys/size"); lc_num=$(cat "$lc_sys/partition")
        for lc_p in "$lc_par"/*/start; do
            [ -r "$lc_p" ] || continue
            [ "$(cat "$lc_p")" -gt "$lc_start" ] && return 0     # ROOT_A is not the last partition
        done
        for lc_p in "$lc_par"/*/partition; do
            [ -r "$lc_p" ] || continue
            [ "$(cat "$lc_p")" -le "$lc_num" ] || return 0       # a partition numbered after ROOT_A
        done
        echo "$lc_dump" | grep -Eq 'type=(5|f|85)(,|$)' && { log_warning_msg "layout: extended partition present, skipping"; return 0; }
        lc_cnt=$(echo "$lc_dump" | grep -c '^/dev/')
        [ "$lc_cnt" = "$lc_num" ] || return 0                    # partitions 1..ROOT_A must all exist
        [ "$lc_num" -le 3 ] || { log_warning_msg "layout: no free primary partition, skipping"; return 0; }
        lc_dsz=$(cat "/sys/block/${lc_ddev##*/}/size")
        [ "$lc_dsz" -le "$LAYOUT_MBR_MAX_SECTORS" ] || { log_warning_msg "layout: disk over 2 TiB, MBR cannot address it, skipping"; return 0; }
        lc_bs=$(( (lc_start + lc_size + 2047) / 2048 * 2048 ))   # 1 MiB aligned
        lc_free=$((lc_dsz - lc_bs))
        if [ "$lc_num" -le 2 ] && [ "$lc_free" -ge $((lc_size + LAYOUT_MBR_MIN_FREE)) ]; then
            lc_ds=$(( (lc_bs + lc_size + 2047) / 2048 * 2048 ))
            lc_new="start=${lc_bs}, size=${lc_size}, type=da
start=${lc_ds}, size=$((lc_dsz - lc_ds)), type=db"
            lc_areas="$lc_bs $lc_ds"; lc_want=2
        elif [ "$lc_free" -ge "$LAYOUT_MBR_MIN_FREE" ]; then
            lc_new="start=${lc_bs}, size=$((lc_dsz - lc_bs)), type=db"
            lc_areas="$lc_bs"; lc_want=1
        else
            log_warning_msg "layout: not enough free space for DATA, skipping"; return 0
        fi
        for lc_z in $lc_areas; do
            dd if=/dev/zero of="$lc_ddev" bs=512 seek="$lc_z" count=2048 conv=notrunc >/dev/null 2>&1 \
                || { log_warning_msg "layout: cannot clear the new areas, skipping"; return 0; }
        done
        printf '%s\n' "$lc_new" | sfdisk --append --no-reread -q "$lc_ddev" >/dev/null 2>&1 \
            || { log_warning_msg "layout: partition table write failed, skipping"; return 0; }
        [ "$(sfdisk -d "$lc_ddev" 2>/dev/null | grep -c '^/dev/')" = $((lc_cnt + lc_want)) ] \
            || { log_warning_msg "layout: partition table check failed after the write, skipping"; return 0; }
        partx -a --nr $((lc_num + 1)) "$lc_ddev" >/dev/null 2>&1
        [ "$lc_want" = 1 ] || partx -a --nr $((lc_num + 2)) "$lc_ddev" >/dev/null 2>&1
        udevadm settle --timeout=2 2>/dev/null || true
    fi

    # Pending partitions (type db DATA, da ROOT_B), DATA first: format, then set the type to 83. Only these types
    # are formatted; a cut between the two steps leaves the fresh filesystem flagged, the next boot formats it again.
    lc_did=""
    for lc_t in db da; do
        lc_line=$(sfdisk -d "$lc_ddev" 2>/dev/null | grep -E "type=${lc_t}(,|\$)" | head -n 1)
        [ -n "$lc_line" ] || continue
        lc_dev=${lc_line%% :*}
        lc_num=$(echo "$lc_dev" | sed 's/.*[^0-9]//')
        if [ "$lc_t" = db ]; then lc_name=DATA; else lc_name=ROOT_B; fi
        [ -b "$lc_dev" ] || { partx -a --nr "$lc_num" "$lc_ddev" >/dev/null 2>&1; udevadm settle --timeout=2 2>/dev/null || true; }
        [ -b "$lc_dev" ] || { log_warning_msg "layout: kernel did not take $lc_name, skipping"; return 0; }
        mke2fs -t ext4 -b 4096 -F -q -L "$lc_name" "$lc_dev" >/dev/null 2>&1 \
            || { log_warning_msg "layout: mke2fs $lc_name failed"; return 0; }
        sfdisk --part-type --no-reread --no-tell-kernel --wipe never --wipe-partitions never "$lc_ddev" "$lc_num" 83 >/dev/null 2>&1 \
            || { log_warning_msg "layout: cannot set the type of $lc_name"; return 0; }
        lc_did="$lc_did $lc_name"
    done
    [ -z "$lc_did" ] || log_success_msg "layout: created${lc_did}"
    return 0
}
# overlay_status STATE: writes the one-line overlay outcome to $OVERLAY_STATUS_FILE and logs it with the "overlay:"
# prefix. States: ok (overlays on DATA); volatile:no-data, volatile:data-mount (overlays on a tmpfs, no DATA);
# failed:overlay-<dir>, failed:dpkg-pin (DATA overlays); failed:volatile (tmpfs overlays failed, root as is).
# The initramfs moves /run to the root; the record on DATA carries the same state.
OVERLAY_STATUS_FILE=${UNITOTEM_OVERLAY_STATUS:-/run/unitotem-overlay.status}
overlay_status() {
    mkdir -p "${OVERLAY_STATUS_FILE%/*}" 2>/dev/null
    echo "$1" > "$OVERLAY_STATUS_FILE" 2>/dev/null || log_warning_msg "overlay: cannot write $OVERLAY_STATUS_FILE"
    case "$1" in
        ok) log_success_msg "overlay: status ok" ;;
        *) log_warning_msg "overlay: status $1" ;;
    esac
}
# mount_overlays BASE: the overlays of etc, root and var on ROOT, with upper/ and work/ under BASE, and the dpkg
# pin. Reads $slot_sfx and $rootmnt. Sets dpkg_pin (skip, stashed, yes, FAILED) and ov_fail (the first failure of
# this call: overlay-<dir> or dpkg-pin, empty when none).
mount_overlays() {
    mo_base=$1
    ov_fail=""
    # /var/lib/dpkg must NOT follow the overlay: it inventories the files on ROOT and an OTA replaces the whole
    # partition, so they must stay one consistent pair. It is bind-mounted to a stash first and bound back over the
    # overlay afterwards; drift in the DATA upper is discarded, ROOT is authoritative.
    DPKG_STASH="${mo_base}/.dpkg-lower"
    dpkg_pin=skip
    if [ -d "${rootmnt}/var/lib/dpkg" ]; then
        mkdir -p "$DPKG_STASH"
        mount --bind "${rootmnt}/var/lib/dpkg" "$DPKG_STASH" 2>/dev/null \
            && dpkg_pin=stashed
    fi

    # The real util-linux mount/umount/losetup/mkfifo are force-copied in by ota-hook (the klibc stubs do not work); the
    # overlay module is listed in conf/modules. --make-rshared/--make-shared below are required by the mount arrangement.
    # /var is overlaid like /etc: with a read-only root, everything outside fstab's tmpfs allowlist would stay read-only
    # (journald, logrotate, wtmp...). An overlay keeps the lower layer visible (dpkg database, /var/unitotem-venv); a
    # tmpfs over /var/lib would hide it.
    for d in etc root var; do
        mkdir -p "${mo_base}/upper/${d}${slot_sfx}" \
                 "${mo_base}/work/${d}${slot_sfx}"
        mount --make-rshared "${rootmnt}" 2>/dev/null || true
        mount -t overlay overlay \
            -o lowerdir="${rootmnt}/${d}",upperdir="${mo_base}/upper/${d}${slot_sfx}",workdir="${mo_base}/work/${d}${slot_sfx}" \
            "${rootmnt}/${d}" \
            || { log_warning_msg "overlay: /${d} failed"; [ -n "$ov_fail" ] || ov_fail=overlay-$d; }
        mount --make-shared "${rootmnt}/${d}" 2>/dev/null || true
    done

    # Now that /var carries the overlay, put ROOT's dpkg database back on top of
    # it. The stash is unmounted straight after (the two binds share the same superblock), so no
    # orphaned mount is left over switch_root (see the /boot-ota note in deploy/ota-engine.sh).
    if [ "$dpkg_pin" = stashed ]; then
        if mount --bind "$DPKG_STASH" "${rootmnt}/var/lib/dpkg" 2>/dev/null; then
            dpkg_pin=yes
        else
            dpkg_pin=FAILED
            [ -n "$ov_fail" ] || ov_fail=dpkg-pin
            log_warning_msg "overlay: /var/lib/dpkg not pinned to ROOT"
        fi
        umount "$DPKG_STASH" 2>/dev/null || true
        rmdir "$DPKG_STASH" 2>/dev/null || true
    fi
}

# Tmpfs holding the volatile overlays. Overridable for tests; the initramfs uses /volatile.
VOLATILE_DIR=${UNITOTEM_VOLATILE_DIR:-/volatile}
# volatile_size: tmpfs size in MiB, MemTotal / 8 clamped to 32..128; 64 when /proc/meminfo is unreadable.
volatile_size() {
    vs_kb=$(sed -n 's/^MemTotal: *\([0-9][0-9]*\) kB$/\1/p' /proc/meminfo 2>/dev/null)
    case "$vs_kb" in ''|*[!0-9]*) echo 64; return 0 ;; esac
    vs_n=$((vs_kb / 8192))
    [ "$vs_n" -ge 32 ] || vs_n=32
    [ "$vs_n" -le 128 ] || vs_n=128
    echo "$vs_n"
}
# volatile_overlays REASON: no usable DATA (REASON no-data, or data-mount). The overlays of etc, root and var use
# a tmpfs as upper and work layer: ROOT is writable for this boot only, and no DATA record is written. The tmpfs
# mount point is released once the overlays hold it; a failure leaves ROOT as is (failed:volatile).
volatile_overlays() {
    vo_reason=$1
    vo_size=$(volatile_size)
    mkdir -p "$VOLATILE_DIR" 2>/dev/null
    if ! mount -t tmpfs -o "size=${vo_size}m,mode=0755" tmpfs "$VOLATILE_DIR"; then
        overlay_status failed:volatile
        return 0
    fi
    slot_sfx=""
    mount_overlays "$VOLATILE_DIR"
    umount "$VOLATILE_DIR" 2>/dev/null || true
    rmdir "$VOLATILE_DIR" 2>/dev/null || true
    if [ -n "$ov_fail" ]; then
        overlay_status failed:volatile
    else
        overlay_status "volatile:${vo_reason}"
    fi
    return 0
}
# Sourced by tools/release/test_grow_data_inside.sh: only the function is wanted.
[ -z "${UNITOTEM_SOURCE_ONLY:-}" ] || return 0 2>/dev/null || exit 0

case "$1" in prereqs) prereqs; exit 0 ;; esac

. /scripts/functions

# A minimal (flash) image has only the boot partition and ROOT_A: create ROOT_B and DATA first. Best-effort.
layout_complete || true

# blkid can run before udev has settled the DATA device node this early in boot
# (init-bottom, right after mountroot): retry for a bounded time.
DATA_DEV=""
tries=0
while [ -z "$DATA_DEV" ] && [ "$tries" -lt 10 ]; do
    DATA_DEV=$(blkid -L DATA 2>/dev/null)
    [ -n "$DATA_DEV" ] && break
    udevadm settle --timeout=2 2>/dev/null || true
    sleep 1
    tries=$((tries + 1))
done
if [ -z "$DATA_DEV" ]; then
    volatile_overlays no-data
    exit 0
fi

# DATA must be crash-consistent: add a journal if the filesystem has none (while unmounted), then let fsck
# repair what a power cut left behind. -p only touches what is safely fixable; failures are logged, never fatal.
if command -v tune2fs >/dev/null 2>&1 && command -v dumpe2fs >/dev/null 2>&1; then
    dumpe2fs -h "$DATA_DEV" 2>/dev/null | grep -q has_journal \
        || tune2fs -O has_journal "$DATA_DEV" >/dev/null 2>&1 \
        || log_warning_msg "overlay: cannot add a journal to DATA"
fi
if command -v e2fsck >/dev/null 2>&1; then
    e2fsck -p "$DATA_DEV" >/dev/null 2>&1
    data_fsck_rc=$?
    # 0 clean, 1 repaired: both fine. Anything above is worth a line in the log, but never stops the boot.
    [ "$data_fsck_rc" -le 1 ] || log_warning_msg "overlay: e2fsck -p on DATA returned ${data_fsck_rc}"
fi

# First boot from a raw image on a larger disk: use the rest of it. Best-effort, never stops the boot.
grow_data "$DATA_DEV" || true

mkdir -p "${rootmnt}/mnt/data"
if ! mount -t ext4 -o noatime,nodiratime "$DATA_DEV" "${rootmnt}/mnt/data"; then
    volatile_overlays data-mount
    exit 0
fi

# A/B layout: each ROOT slot keeps its own overlay state on DATA (upper/etc.a, upper/etc.b, ...),
# named by unitotem.slot= on the kernel command line, so updating one slot never touches what the
# other needs for a rollback. Without the argument the suffix is empty.
slot_sfx=""
for tok in $(cat /proc/cmdline); do
    case "$tok" in unitotem.slot=a|unitotem.slot=b) slot_sfx=".${tok#unitotem.slot=}" ;; esac
done

# The overlay status is recorded after the mounts (.unitotem-overlay-status on DATA) so the early-boot state can be
# read back after boot. Keep that marker.
mount_overlays "${rootmnt}/mnt/data"

# Record the outcome on DATA (visible at /mnt/data/.unitotem-overlay-status after boot): what this
# script observed in the initramfs, and a write probe proving each overlay is writable, not just
# mounted. Best-effort: never fails the boot.
if [ -n "$ov_fail" ]; then ov_state="failed:$ov_fail"; else ov_state=ok; fi
{
    echo "boot-marker=1"
    echo "overlay-slot-suffix=${slot_sfx:-none}"
    echo "overlay-status=${ov_state}"
    for d in etc root var; do
        if grep -q " ${rootmnt}/${d} overlay " /proc/mounts 2>/dev/null; then
            echo "initramfs-${d}=overlay-mounted"
        else
            echo "initramfs-${d}=NOT-MOUNTED"
        fi
    done
    # `: >` (a shell redirect) rather than touch/rm: this klibc-based initramfs has no touch.
    for d in etc root var; do
        if : > "${rootmnt}/${d}/.unitotem-overlay-writetest" 2>/dev/null; then
            echo "initramfs-${d}-writable=yes"
        else
            echo "initramfs-${d}-writable=no"
        fi
    done
    # Whether the dpkg database is on ROOT or on DATA can only be known from this early-boot state.
    echo "initramfs-dpkg-pinned-to-root=${dpkg_pin}"
} > "${rootmnt}/mnt/data/.unitotem-overlay-status" 2>/dev/null || true
overlay_status "$ov_state"

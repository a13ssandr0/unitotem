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
#      filesystem is smaller than its partition); a cut inside 4 leaves a filesystem that fsck repairs.
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
    [ "$gd_rc" -le 1 ] || { log_warning_msg "grow: e2fsck returned ${gd_rc}, filesystem not grown"; return 0; }
    resize2fs "$gd_dev" >/dev/null 2>&1 || { log_warning_msg "grow: resize2fs failed"; return 0; }
    log_success_msg "grow: DATA grown to $((gd_psz / 2048)) MiB"
    return 0
}
# layout_complete: a minimal image carries only the boot partition(s) and ROOT_A. On the first boot create ROOT_B (same
# size as stage3's slots) and DATA (rest of the disk) in the free space after ROOT_A. State is derived from the disk
# on every boot, no flag file:
#   - neither ROOT_B nor DATA in the GPT, ROOT_A the last partition, >= 5 GiB + 256 MiB free after it:
#       sgdisk -e (valid backup GPT at the disk end), zero the first MiB of both new areas (stale signatures of a
#       reused card), then ONE sgdisk write adds both entries, each flagged "pending" (GPT attribute bit 48);
#   - partx -a tells the kernel about the two new partitions only (ROOT_A, mounted, is not touched);
#   - every partition flagged pending is formatted (ROOT_B: ext4 label ROOT_B, the empty slot that unitotem-update
#     repair fills; DATA: ext4 label DATA, as stage3), then its flag is cleared.
# A cut before the table write changes nothing; a cut after it leaves flagged partitions that the next boot formats
# (only flagged partitions are ever formatted: a damaged filesystem is never reformatted). Never touches ROOT_A or the
# boot partition. Any failure logs one line and returns 0.
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
    [ "$(blkid -p -s PTTYPE -o value "$lc_ddev" 2>/dev/null)" = gpt ] || return 0
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
    log_warning_msg "overlay: DATA not found, skipping"
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
    log_warning_msg "overlay: mounting DATA failed, skipping"
    exit 0
fi

# The overlay status is recorded after the mounts (.unitotem-overlay-status on DATA) so the early-boot state can be
# read back after boot. Keep that marker.
# The real util-linux mount/umount/losetup/mkfifo are force-copied in by ota-hook (the klibc stubs do not work); the
# overlay module is listed in conf/modules. --make-rshared/--make-shared below are required by the mount arrangement.
# /var is overlaid like /etc: with a read-only root, everything outside fstab's tmpfs allowlist would stay read-only
# (journald, logrotate, wtmp...). An overlay keeps the lower layer visible (dpkg database, /var/unitotem-venv); a
# tmpfs over /var/lib would hide it.
# /var/lib/dpkg must NOT follow the overlay: it inventories the files on ROOT and an OTA replaces the whole partition,
# so they must stay one consistent pair. It is bind-mounted to a stash first and bound back over the overlay
# afterwards; drift in the DATA upper is discarded, ROOT is authoritative.
DPKG_STASH="${rootmnt}/mnt/data/.dpkg-lower"
dpkg_pin=skip
if [ -d "${rootmnt}/var/lib/dpkg" ]; then
    mkdir -p "$DPKG_STASH"
    mount --bind "${rootmnt}/var/lib/dpkg" "$DPKG_STASH" 2>/dev/null \
        && dpkg_pin=stashed
fi

# A/B layout: each ROOT slot keeps its own overlay state on DATA (upper/etc.a, upper/etc.b, ...),
# named by unitotem.slot= on the kernel command line, so updating one slot never touches what the
# other needs for a rollback. Without the argument the suffix is empty.
slot_sfx=""
for tok in $(cat /proc/cmdline); do
    case "$tok" in unitotem.slot=a|unitotem.slot=b) slot_sfx=".${tok#unitotem.slot=}" ;; esac
done

for d in etc root var; do
    mkdir -p "${rootmnt}/mnt/data/upper/${d}${slot_sfx}" \
             "${rootmnt}/mnt/data/work/${d}${slot_sfx}"
    mount --make-rshared "${rootmnt}" 2>/dev/null || true
    mount -t overlay overlay \
        -o lowerdir="${rootmnt}/${d}",upperdir="${rootmnt}/mnt/data/upper/${d}${slot_sfx}",workdir="${rootmnt}/mnt/data/work/${d}${slot_sfx}" \
        "${rootmnt}/${d}" \
        || log_warning_msg "overlay: /${d} failed"
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
        log_warning_msg "overlay: /var/lib/dpkg not pinned to ROOT"
    fi
    umount "$DPKG_STASH" 2>/dev/null || true
    rmdir "$DPKG_STASH" 2>/dev/null || true
fi

# Record the outcome on DATA (visible at /mnt/data/.unitotem-overlay-status after boot): what this
# script observed in the initramfs, and a write probe proving each overlay is writable, not just
# mounted. Best-effort: never fails the boot.
{
    echo "boot-marker=1"
    echo "overlay-slot-suffix=${slot_sfx:-none}"
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

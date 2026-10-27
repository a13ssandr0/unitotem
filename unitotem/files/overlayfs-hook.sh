#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

. /scripts/functions

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

mkdir -p "${rootmnt}/mnt/data"
if ! mount -t ext4 -o noatime,nodiratime "$DATA_DEV" "${rootmnt}/mnt/data"; then
    log_warning_msg "overlay: mounting DATA failed, skipping"
    exit 0
fi

# The overlay status is recorded after the mounts (.unitotem-overlay-status on DATA) so the early-boot
# state can be read back after boot. Keep that marker.
#
# The real util-linux mount/umount/losetup/mkfifo are force-copied into the initramfs by
# unitotem/files/ota-hook, because the klibc stubs are not functional; the overlay module is
# listed in conf/modules.
#
# --make-rshared/--make-shared below are required by the current mount arrangement.
#
# /var is overlaid like /etc: with a read-only root, everything under /var outside fstab's tmpfs
# allowlist would stay read-only (journald could not use /var/log/journal and every reboot
# discarded the logs; logrotate, dpkg-db-backup and wtmp could not write either). An overlay keeps
# the lower layer visible (dpkg's database, /var/unitotem-venv) and only diverts writes; a tmpfs
# over /var/lib would hide them.
#
# /var/lib/dpkg must NOT follow the overlay: it inventories the files installed on ROOT, and an OTA
# replaces the whole partition, so database and files must stay one consistent pair. The ROOT copy
# is no longer reachable once /var is overlaid, so it is bind-mounted to a stash first and bound
# back over the overlay afterwards. Any drift in the DATA upper is discarded; ROOT is authoritative.
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

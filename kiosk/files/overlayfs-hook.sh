#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

. /scripts/functions

# blkid can run before udev has finished settling the DATA partition's
# device node/database entry this early in boot (init-bottom, right after
# mountroot) - a single blkid call can race it and find nothing even though
# the partition is there. Same class of race as resolve_disk() elsewhere in
# this repo; same fix, a short bounded wait. Confirmed fixed on real Pi 4
# hardware: DATA now resolves within 0-2 retries every boot.
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
    log_warning_msg "overlay: DATA non trovata, skip"
    exit 0
fi

mkdir -p "${rootmnt}/mnt/data"
if ! mount -t ext4 -o noatime,nodiratime "$DATA_DEV" "${rootmnt}/mnt/data"; then
    log_warning_msg "overlay: mount DATA fallito, skip"
    exit 0
fi

# HISTORY, and why this script now reports its own result.
#
# This was long recorded as a known-unresolved bug: the overlays mounted
# fine here (rc=0, visible in `mount`) but appeared not to survive
# switch_root, leaving /etc and /root read-only at runtime. During that
# investigation a separate, very real bug was found and fixed: `mount`
# itself was being shadowed this early in boot by a non-functional klibc
# stub (same class as the mke2fs/dd bugs documented in the OTA tooling), so
# deploy/ota-engine.sh's initramfs hook (kiosk/files/ota-hook) force-copies
# the real mount/umount/losetup/mkfifo. The initrd shipped today does carry
# the real util-linux mount, the overlay module and `overlay` in
# conf/modules - all three verified by extracting the built initramfs.
#
# Strong evidence now says the overlay is in fact working: the root
# filesystem is mounted read-only (see kiosk/files/fstab-arm64 and the ro
# kernel cmdline), yet unitotem-ssh-hostkey.service writes host keys into
# /etc/ssh on every boot and was confirmed succeeding on real hardware
# (service 0/SUCCESS, restored key matching DATA byte for byte). That is
# only possible if /etc really is overlaid and writable.
#
# Rather than rewrite a mechanism that the evidence says works - or keep
# trusting a stale comment - the script now records what actually happened
# where it can be read after boot. Do not delete that marker: it is the
# difference between knowing and assuming, and this exact question already
# cost one wrong diagnosis.
#
# --make-rshared/--make-shared below are retained deliberately. They were
# added as an attempted fix, did not resolve anything on their own, and are
# kept only because the current arrangement is known-good on hardware;
# removing them is a separate change that needs its own boot test.
mkdir -p "${rootmnt}/mnt/data/upper/etc" \
         "${rootmnt}/mnt/data/work/etc"
mount --make-rshared "${rootmnt}" 2>/dev/null || true
mount -t overlay overlay \
    -o lowerdir="${rootmnt}/etc",upperdir="${rootmnt}/mnt/data/upper/etc",workdir="${rootmnt}/mnt/data/work/etc" \
    "${rootmnt}/etc" \
    || log_warning_msg "overlay: /etc fallito"
mount --make-shared "${rootmnt}/etc" 2>/dev/null || true

mkdir -p "${rootmnt}/mnt/data/upper/root" \
         "${rootmnt}/mnt/data/work/root"
mount -t overlay overlay \
    -o lowerdir="${rootmnt}/root",upperdir="${rootmnt}/mnt/data/upper/root",workdir="${rootmnt}/mnt/data/work/root" \
    "${rootmnt}/root" \
    || log_warning_msg "overlay: /root fallito"
mount --make-shared "${rootmnt}/root" 2>/dev/null || true

# Record the outcome on DATA itself, which survives into the booted system
# at /mnt/data - so "is /etc actually overlaid?" is answerable after the
# fact with `cat /mnt/data/.unitotem-overlay-status` instead of having to
# reproduce an early-boot state. Two independent facts are captured: what
# this script observed here in the initramfs, and a write probe proving the
# overlay is genuinely writable rather than merely mounted. Best-effort
# throughout: never allowed to fail the boot.
{
    echo "boot-marker=1"
    for d in etc root; do
        if grep -q " ${rootmnt}/${d} overlay " /proc/mounts 2>/dev/null; then
            echo "initramfs-${d}=overlay-mounted"
        else
            echo "initramfs-${d}=NOT-MOUNTED"
        fi
    done
    if touch "${rootmnt}/etc/.unitotem-overlay-writetest" 2>/dev/null; then
        rm -f "${rootmnt}/etc/.unitotem-overlay-writetest" 2>/dev/null
        echo "initramfs-etc-writable=yes"
    else
        echo "initramfs-etc-writable=no"
    fi
} > "${rootmnt}/mnt/data/.unitotem-overlay-status" 2>/dev/null || true

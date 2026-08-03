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

# KNOWN UNRESOLVED ISSUE (found and diagnosed on real Pi 4 hardware,
# 2026-07-30, during the OTA redesign work - not something that regressed
# just now): both overlay mounts below succeed here (verified rc=0, and
# `mount` shows them live, right up to the end of this script) but do NOT
# survive the subsequent switch_root into the real system - `findmnt /etc
# /root` on the booted system shows nothing. --make-rshared/--make-shared
# (the standard fix for "custom submount doesn't survive switch_root") was
# tried and did NOT resolve it either. Net effect: /etc and /root are
# NOT actually overlaid/writable at runtime today, despite this script
# reporting success. A separate, real bug was ALSO found and fixed in the
# same investigation: `mount` itself was being shadowed by a non-functional
# klibc stub this early in boot (busybox-initramfs/klibc-utils hook-
# ordering issue, same class as the mke2fs/dd bugs documented in the OTA
# tooling) - deploy/ota-engine.sh's initramfs hook (kiosk/files/ota-hook)
# force-copies the real mount/umount/losetup/mkfifo for exactly this
# reason, which also benefits this script once the image is rebuilt with
# it. That fix alone was NOT sufficient to make the overlay survive
# switch_root, though - the propagation issue is a separate, still-open
# problem. Likely next step if picked back up: do the overlay mount from a
# systemd unit ordered before local-fs.target on the REAL system instead of
# from here (i.e. once PID 1 has already taken over the final, stable mount
# namespace), rather than continuing to fight switch_root's mount handoff
# from inside the initramfs.
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

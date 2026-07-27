#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac

. /scripts/functions

DATA_DEV=$(blkid -L DATA 2>/dev/null)
if [ -z "$DATA_DEV" ]; then
    log_warning_msg "overlay: DATA non trovata, skip"
    exit 0
fi

mkdir -p "${rootmnt}/mnt/data"
if ! mount -t ext4 -o noatime,nodiratime "$DATA_DEV" "${rootmnt}/mnt/data"; then
    log_warning_msg "overlay: mount DATA fallito, skip"
    exit 0
fi

mkdir -p "${rootmnt}/mnt/data/upper/etc" \
         "${rootmnt}/mnt/data/work/etc"
mount -t overlay overlay \
    -o lowerdir="${rootmnt}/etc",upperdir="${rootmnt}/mnt/data/upper/etc",workdir="${rootmnt}/mnt/data/work/etc" \
    "${rootmnt}/etc" \
    || log_warning_msg "overlay: /etc fallito"

mkdir -p "${rootmnt}/mnt/data/upper/root" \
         "${rootmnt}/mnt/data/work/root"
mount -t overlay overlay \
    -o lowerdir="${rootmnt}/root",upperdir="${rootmnt}/mnt/data/upper/root",workdir="${rootmnt}/mnt/data/work/root" \
    "${rootmnt}/root" \
    || log_warning_msg "overlay: /root fallito"

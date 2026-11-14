#!/bin/bash
# grow.sh IMG SIZE: grows the last partition (ROOT) and its ext4 offline.
set -euo pipefail
IMG=$1; SZ=$2
truncate -s "$SZ" "$IMG"
sgdisk -e "$IMG" >/dev/null
sgdisk -d2 -n2:0:0 -t2:8300 -c2:ROOT "$IMG" >/dev/null
L=$(losetup --show -fP "$IMG"); trap 'losetup -d "$L"' EXIT
e2fsck -fy "${L}p2" >/dev/null || true
resize2fs "${L}p2" >/dev/null
blkid "${L}p2"

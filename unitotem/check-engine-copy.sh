#!/bin/bash
# Is the OTA engine inside an initramfs the engine of the repository?
#   check-engine-copy.sh INITRD ENGINE.sh
# The initramfs carries a copy (usr/lib/unitotem/ota-engine.sh); stage 1 installs it and stage 1b/stage 2 refresh it. A copy from an older stage 1
# tarball runs the old fallback. Exit 0 identical, 1 different or absent, 2 the initramfs cannot be read.
set -uo pipefail
[ $# -eq 2 ] || { echo "usage: $0 INITRD ENGINE.sh" >&2; exit 2; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/engine-copy.XXXXXX") || exit 2
trap 'rm -rf -- "$TMP"' EXIT
# the last entry wins, as on extraction; initrd-scan.py reads the zstd-plus-appended layout that lsinitramfs cannot
python3 -I "$HERE/initrd-scan.py" get "$1" usr/lib/unitotem/ota-engine.sh > "$TMP/copy" 2> "$TMP/err"; rc=$?
case "$rc" in
    0) ;;
    1) echo "no usr/lib/unitotem/ota-engine.sh in $1" >&2; exit 1 ;;
    *) cat "$TMP/err" >&2; exit 2 ;;
esac
cmp -s -- "$TMP/copy" "$2" || { echo "the ota-engine.sh in $1 differs from $2" >&2; exit 1; }
echo "engine copy identical"

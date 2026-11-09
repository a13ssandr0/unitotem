#!/bin/bash
# Test of layout_complete on DOS (MBR) disks (unitotem/files/overlayfs-hook.sh, layout_mbr): first-boot creation of
# ROOT_B and DATA with primaries, power-cut recovery, and the GPT path left unchanged.
# Needs docker with --privileged (loop devices, partition tables and mounts happen only INSIDE the container).
# Scratch: work/layout-dos-test/ (sparse files, removed at the end by a disposable container).
#   tools/release/test_first_boot_layout_dos.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/layout-dos-test"
docker rm -f layout-dos-test >/dev/null 2>&1 || true
rc=0
docker run --name layout-dos-test --privileged \
    -v "${DIR}:/repo:ro" -v "${DIR}/work/layout-dos-test:/work" --workdir /work \
    debian:trixie bash /repo/tools/release/test_first_boot_layout_dos_inside.sh "$@" || rc=$?
docker rm -f layout-dos-test >/dev/null 2>&1 || true
docker run --rm -v "${DIR}/work:/w" debian:trixie rm -rf -- /w/layout-dos-test/dos-a.img /w/layout-dos-test/dos-4.img /w/layout-dos-test/dos-ext.img /w/layout-dos-test/dos-after.img /w/layout-dos-test/t.img /w/layout-dos-test/gpt.img /w/layout-dos-test/d.img || true
exit "$rc"

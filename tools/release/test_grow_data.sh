#!/bin/bash
# Test of grow_data (unitotem/files/overlayfs-hook.sh): first-boot growth of DATA to the disk end.
# Needs docker with --privileged (loop devices, partition tables and mounts happen only INSIDE the container).
# Scratch: work/grow-test/ (sparse files, removed at the end by a disposable container).
#   tools/release/test_grow_data.sh [--big]     --big adds the 400 GB timing runs
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/grow-test"
docker rm -f grow-test >/dev/null 2>&1 || true
rc=0
docker run --name grow-test --privileged -e PHASE2_ONLY="${PHASE2_ONLY:-0}" \
    -v "${DIR}:/repo:ro" -v "${DIR}/work/grow-test:/work" --workdir /work \
    debian:trixie bash /repo/tools/release/test_grow_data_inside.sh "$@" || rc=$?
docker rm -f grow-test >/dev/null 2>&1 || true
docker run --rm -v "${DIR}/work:/w" debian:trixie rm -rf -- /w/grow-test/base-amd64.img /w/grow-test/base-arm64.img /w/grow-test/t.img /w/grow-test/big.img /w/grow-test/flash-amd64.img /w/grow-test/flash-arm64.img || true
exit "$rc"

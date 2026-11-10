#!/bin/bash
# Test of the duplicate-label recovery: unitotem-update clone_into_slot / slot_dev and deploy/ota-engine.sh slot_pick,
# heal_dup_label, pin_root_dev, cmd_init_premount. Needs docker with --privileged (loop devices, partitions and mounts
# happen only INSIDE the container). Scratch: work/slot-dup-test/ (sparse files, removed at the end by a disposable container).
#   tools/release/test_slot_dup.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/slot-dup-test"
docker rm -f slot-dup-test >/dev/null 2>&1 || true
rc=0
timeout 1500 docker run --name slot-dup-test --privileged \
    -v "${DIR}:/repo:ro" -v "${DIR}/work/slot-dup-test:/work" --workdir /work \
    debian:trixie bash /repo/tools/release/test_slot_dup_inside.sh || rc=$?
docker rm -f slot-dup-test >/dev/null 2>&1 || true
docker run --rm -v "${DIR}/work:/w" debian:trixie rm -rf -- /w/slot-dup-test || true
exit "$rc"

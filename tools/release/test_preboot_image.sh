#!/bin/bash
# Test of the preboot card: deploy/script/make-preboot-image.sh (--tree and --image), write-preboot.sh and unitotem/make-boot-tree.sh.
# The card: one FAT partition (MBR, type 0c, from 1 MiB), the boot tree (firmware, the recovery kernel and initrd with the repository's
# engine, no password or key anywhere). Privileged container (loop devices, mount); scratch in work/preboot-test/t.
#   tools/release/test_preboot_image.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/preboot-test"
rc=0
docker build -q -f "${DIR}/tools/release/Dockerfile.test" -t unitotem-test-tools "${DIR}/tools/release" >/dev/null
docker run --rm --privileged -v "${DIR}:/repo:ro" -v "${DIR}/work/preboot-test:/work" --workdir /work \
    unitotem-test-tools:latest bash /repo/tools/release/test_preboot_image_inside.sh || rc=$?
# the container wrote root-owned files: removed by a disposable container, never sudo
docker run --rm -v "${DIR}/work/preboot-test:/w" debian:trixie sh -c 'rm -rf -- /w/t' || true
exit "$rc"

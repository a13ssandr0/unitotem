#!/bin/bash
# Test of deploy/script/write-sd.sh: an image written to a (loop) disk gets the same partition table, the same filesystems
# (label, UUID, files) and the raw partition; only the used blocks are written; refusals. Everything happens INSIDE a privileged
# container (loop devices): nothing on the host is touched. Scratch: work/write-sd-test/ (sparse files, removed at the end).
#   tools/release/test_write_sd.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/write-sd-test"
rc=0
docker build -q -f "${DIR}/tools/release/Dockerfile.test" -t unitotem-test-tools "${DIR}/tools/release" >/dev/null
docker run --rm --privileged -v "${DIR}:/repo:ro" -v "${DIR}/work/write-sd-test:/work" --workdir /work \
    unitotem-test-tools:latest bash /repo/tools/release/test_write_sd_inside.sh || rc=$?
docker run --rm -v "${DIR}/work:/w" debian:trixie sh -c 'rm -f -- /w/write-sd-test/src.img /w/write-sd-test/src.img.xz /w/write-sd-test/dst1.img /w/write-sd-test/dst2.img /w/write-sd-test/small.img /w/write-sd-test/min.img /w/write-sd-test/mindos.img /w/write-sd-test/dst3.img /w/write-sd-test/dst4.img /w/write-sd-test/w3.log /w/write-sd-test/w4.log' || true
exit "$rc"

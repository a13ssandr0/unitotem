#!/bin/bash
# Test of unitotem/shrink-root-image.sh on synthetic small images (GPT as amd64, DOS as arm64), of the arm64 DOS table
# written by unitotem/stage3-image.sh (dos_table), and of the first-boot layout completion of the shrunk DOS image.
# Needs docker with --privileged (loop devices and partition tables happen only INSIDE the container).
# Scratch: work/shrink-root-image-test/ (the log of the last run stays there).
#   tools/release/test_shrink_root_image.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/shrink-root-image-test"
docker rm -f shrink-root-image-test >/dev/null 2>&1 || true
rc=0
docker run --name shrink-root-image-test --privileged \
    -v "${DIR}:/repo:ro" -v "${DIR}/work/shrink-root-image-test:/work" --workdir /work \
    debian:trixie bash /repo/tools/release/test_shrink_root_image_inside.sh "$@" || rc=$?
docker rm -f shrink-root-image-test >/dev/null 2>&1 || true
docker run --rm -v "${DIR}/work:/w" debian:trixie rm -f -- /w/shrink-root-image-test/dos.img /w/shrink-root-image-test/gpt.img /w/shrink-root-image-test/disk.img /w/shrink-root-image-test/dos3.img /w/shrink-root-image-test/dos-before.img /w/shrink-root-image-test/gpt-before.img /w/shrink-root-image-test/dos_table.fn || true
exit "$rc"

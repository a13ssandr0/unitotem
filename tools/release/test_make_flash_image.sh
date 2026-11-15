#!/bin/bash
# Test of unitotem/make-flash-image.sh on synthetic small GPT full images: arm64 gives a DOS flash image (FIRMWARE c
# bootable, ROOT_A 83) that layout_mbr completes to four primaries; amd64 stays GPT. Needs docker with --privileged
# (loop devices and partition tables happen only INSIDE the container). Scratch: work/mbr-all/flash-image-test/.
#   tools/release/test_make_flash_image.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/mbr-all/flash-image-test"
docker rm -f make-flash-image-test >/dev/null 2>&1 || true
rc=0
docker run --name make-flash-image-test --privileged \
    -v "${DIR}:/repo:ro" -v "${DIR}/work/mbr-all/flash-image-test:/work" --workdir /work \
    debian:trixie bash /repo/tools/release/test_make_flash_image_inside.sh "$@" || rc=$?
docker rm -f make-flash-image-test >/dev/null 2>&1 || true
docker run --rm -v "${DIR}/work/mbr-all:/w" debian:trixie rm -rf -- /w/flash-image-test/arm64-full.img /w/flash-image-test/arm64-flash.img /w/flash-image-test/amd64-full.img /w/flash-image-test/amd64-flash.img /w/flash-image-test/arm64-min-full.img /w/flash-image-test/arm64-min-flash.img /w/flash-image-test/amd64-min-full.img /w/flash-image-test/amd64-min-flash.img /w/flash-image-test/disk.img || true
exit "$rc"

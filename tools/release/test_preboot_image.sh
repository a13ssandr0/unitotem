#!/bin/bash
# Test of deploy/script/make-preboot-image.sh: the preboot SD image (one FAT partition, firmware read from an arm64 image, the recovery kernel and
# initrd, the repository's engine appended to the initrd, no password or key anywhere). Privileged container (loop device, mount).
#   tools/release/test_preboot_image.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/preboot-test"
rc=0
docker build -q -f "${DIR}/tools/release/Dockerfile.test" -t unitotem-test-tools "${DIR}/tools/release" >/dev/null
docker run --rm --privileged -v "${DIR}:/repo:ro" -v "${DIR}/work/preboot-test:/work" --workdir /work \
    unitotem-test-tools:latest bash /repo/tools/release/test_preboot_image_inside.sh || rc=$?
docker run --rm -v "${DIR}/work:/w" debian:trixie sh -c 'rm -f -- /w/preboot-test/fake.img /w/preboot-test/out.img /w/preboot-test/card.img /w/preboot-test/wp.img /w/preboot-test/wp.img.xz /w/preboot-test/vmlinuz /w/preboot-test/initrd /w/preboot-test/engine.sh /w/preboot-test/old-engine.sh' || true
exit "$rc"

#!/bin/bash
# Test of deploy/script/image-lib.sh: an image is read in place (tmpfs only for the expansion), described for the deploy and streamed per
# partition in the format the OTA engine restores. Runs in a privileged container (loop devices). Scratch: work/image-lib-test/.
#   tools/release/test_image_lib.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "${DIR}/work/image-lib-test"
rc=0
docker build -q -f "${DIR}/tools/release/Dockerfile.test" -t unitotem-test-tools "${DIR}/tools/release" >/dev/null
docker run --rm --privileged -v "${DIR}:/repo:ro" -v "${DIR}/work/image-lib-test:/work" --workdir /work \
    unitotem-test-tools:latest bash /repo/tools/release/test_image_lib_inside.sh || rc=$?
docker run --rm -v "${DIR}/work:/w" debian:trixie sh -c 'rm -f -- /w/image-lib-test/src.img /w/image-lib-test/src.img.xz /w/image-lib-test/tgt.img' || true
exit "$rc"

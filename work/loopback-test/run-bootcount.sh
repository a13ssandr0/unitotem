#!/bin/bash
# Driver for inside-bootcount.sh.
# No parts set is needed: the harness builds its own minimal disk, because cmd_init_premount
# only looks at the FIRMWARE and ROOT labels and reads nothing from an image's contents.
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "${DIR}/work/loopback-test/scratch-bootcount"

# Explicit --platform: the local cache may hold the arm64 debian:bookworm pulled by
# run-arm64.sh, and cmd_init_premount has no arch-specific branches, so no emulation is needed.
docker run --rm --privileged --platform linux/amd64 \
    -v "${DIR}:/repo:ro" \
    -v "${DIR}/work/loopback-test:/work/driver:ro" \
    -v "${DIR}/work/loopback-test/scratch-bootcount:/work" \
    --workdir /work \
    debian:bookworm \
    bash /work/driver/inside-bootcount.sh

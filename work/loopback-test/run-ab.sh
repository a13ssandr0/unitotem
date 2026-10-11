#!/bin/bash
# Host driver for inside-ab.sh. Usage: run-ab.sh <path to an A/B .parts dir>. Leaves the deployed disk in
# work/loopback-test/scratch-ab/target.img so it can be booted in QEMU.
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARTS_DIR="$(cd "${1:?uso: run-ab.sh <parts dir>}" && pwd)"
mkdir -p "${DIR}/work/loopback-test/scratch-ab"
docker run --rm --privileged --platform linux/amd64 -e ARCH="${ARCH:-amd64}" \
    -v "${DIR}:/repo:ro" -v "${PARTS_DIR}:/work/parts:ro" -v "${DIR}/work/loopback-test:/work/driver:ro" \
    -v "${DIR}/work/loopback-test/scratch-ab:/work" --workdir /work \
    debian:bookworm bash /work/driver/inside-ab.sh

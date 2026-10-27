#!/bin/bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARTS_DIR="${1:?usage: run-arm64.sh <path to the .parts dir>}"
[ -d "$PARTS_DIR" ] || { echo "not found: $PARTS_DIR" >&2; exit 1; }
PARTS_DIR="$(cd "$PARTS_DIR" && pwd)"

mkdir -p "${DIR}/work/loopback-test/scratch-arm64"

docker run --rm --privileged \
    -v "${DIR}:/repo:ro" \
    -v "${PARTS_DIR}:/work/parts:ro" \
    -v "${DIR}/work/loopback-test:/work/driver:ro" \
    -v "${DIR}/work/loopback-test/scratch-arm64:/work" \
    --workdir /work \
    debian:bookworm \
    bash /work/driver/inside-arm64.sh

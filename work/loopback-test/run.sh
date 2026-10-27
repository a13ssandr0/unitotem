#!/bin/bash
# Host-side entry point for the loopback verification: runs work/loopback-test/inside.sh
# as root inside a throwaway --privileged container (loop/mount/chroot need root, and the
# container gives it without touching the host).
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARTS_DIR="${1:?usage: run.sh <path to the .parts dir>}"
[ -d "$PARTS_DIR" ] || { echo "not found: $PARTS_DIR" >&2; exit 1; }
PARTS_DIR="$(cd "$PARTS_DIR" && pwd)"   # docker -v needs an absolute path

mkdir -p "${DIR}/work/loopback-test/scratch"

docker run --rm --privileged \
    -v "${DIR}:/repo:ro" \
    -v "${PARTS_DIR}:/work/parts:ro" \
    -v "${DIR}/work/loopback-test:/work/driver:ro" \
    -v "${DIR}/work/loopback-test/scratch:/work" \
    --workdir /work \
    debian:bookworm \
    bash /work/driver/inside.sh

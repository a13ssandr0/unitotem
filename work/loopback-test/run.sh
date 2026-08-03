#!/bin/bash
# Host-side entry point for the §11.1 loopback verification: runs
# work/loopback-test/inside.sh as root inside a throwaway --privileged
# container (this dev host has no passwordless sudo, so loop/mount/chroot
# operations can't happen directly on the host - a disposable privileged
# container gives real root without touching the host at all).
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARTS_DIR="${1:?uso: run.sh <path ai .parts>}"
[ -d "$PARTS_DIR" ] || { echo "non trovato: $PARTS_DIR" >&2; exit 1; }
PARTS_DIR="$(cd "$PARTS_DIR" && pwd)"   # docker -v richiede un path assoluto

mkdir -p "${DIR}/work/loopback-test/scratch"

docker run --rm --privileged \
    -v "${DIR}:/repo:ro" \
    -v "${PARTS_DIR}:/work/parts:ro" \
    -v "${DIR}/work/loopback-test:/work/driver:ro" \
    -v "${DIR}/work/loopback-test/scratch:/work" \
    --workdir /work \
    debian:bookworm \
    bash /work/driver/inside.sh

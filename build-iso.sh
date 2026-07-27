#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

DOCKER="${DOCKER:-docker}"

if ! ${DOCKER} info >/dev/null 2>&1; then
    echo "Docker not available or not running" >&2
    exit 1
fi

echo ">>> Building ISO builder image..."
${DOCKER} build -f "${DIR}/Dockerfile.iso" -t kiosk-iso-builder "${DIR}"

mkdir -p "${DIR}/deploy"

echo ">>> Building installer ISO..."
${DOCKER} run --rm --privileged \
    -v "${DIR}/deploy:/deploy" \
    kiosk-iso-builder /iso-src/build-live.sh

echo ""
echo "ISO ready:"
ls -lh "${DIR}/deploy/"*installer*.iso 2>/dev/null || ls -lh "${DIR}/deploy/"

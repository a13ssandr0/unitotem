#!/bin/bash
# Builds the deploy flasher: a small standalone kernel+initrd pair (per
# ARCH) that boots into deploy/flasher/unitotem-flash and nothing else. Used
# by deploy/remote-deploy.sh to arm a remote machine's one-shot boot entry.
#
# Mirrors build-kiosk.sh's docker-driven structure, but the per-arch driver
# is deploy/flasher-image.sh instead of the kiosk/stageN.sh scripts, and it
# consumes work/$ARCH/stage2.tar.gz (already-configured kiosk rootfs) rather
# than rebuilding one - run build-kiosk.sh first (through at least stage 2)
# for each ARCH you want a flasher for.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOCKER="${DOCKER:-docker}"
ARCHES="${ARCHES:-amd64 arm64}"

if ! ${DOCKER} info >/dev/null 2>&1; then
    echo "Docker not available or not running" >&2
    exit 1
fi

echo ">>> Setting up QEMU binfmt handlers..."
${DOCKER} run --rm --privileged tonistiigi/binfmt --install arm64 2>/dev/null \
    || ${DOCKER} run --rm --privileged multiarch/qemu-user-static --reset -p yes \
    || echo "Warning: could not register binfmt handlers (may already be registered)"

echo ">>> Building flasher builder image..."
${DOCKER} build -f "${DIR}/Dockerfile.flasher" -t kiosk-flasher-builder "${DIR}"

mkdir -p "${DIR}/work" "${DIR}/deploy"

for ARCH in ${ARCHES}; do
    echo ""
    echo "=================================================="
    echo "  Building flasher for ARCH=${ARCH}"
    echo "=================================================="

    if [ ! -f "${DIR}/work/${ARCH}/stage2.tar.gz" ]; then
        echo "work/${ARCH}/stage2.tar.gz missing - run ./build-kiosk.sh first (ARCHES=${ARCH})" >&2
        exit 1
    fi

    mkdir -p "${DIR}/deploy/${ARCH}"

    ${DOCKER} run --rm --privileged \
        -v /dev:/dev \
        -v "${DIR}/work:/work" \
        -v "${DIR}/deploy:/deploy" \
        -e "ARCH=${ARCH}" \
        kiosk-flasher-builder /kiosk/flasher-image.sh

    echo "[${ARCH}] Done! Flasher in: deploy/${ARCH}/flash-{vmlinuz,initrd-}${ARCH}.img"
done

echo ""
echo "All flasher builds complete."
ls -lh "${DIR}/deploy"/*/flash-* "${DIR}/deploy"/*/flash.manifest 2>/dev/null || true

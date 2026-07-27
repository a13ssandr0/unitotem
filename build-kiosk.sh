#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER="${DOCKER:-docker}"
ARCHES="${ARCHES:-amd64 arm64}"
FORCE_STAGE="${FORCE_STAGE:-}"   # set to 0,1,2 to force rebuild from that stage onward

if ! ${DOCKER} info >/dev/null 2>&1; then
    echo "Docker not available or not running" >&2
    exit 1
fi

# Register QEMU binfmt for arm64 cross-compilation
echo ">>> Setting up QEMU binfmt handlers..."
${DOCKER} run --rm --privileged tonistiigi/binfmt --install arm64 2>/dev/null \
    || ${DOCKER} run --rm --privileged multiarch/qemu-user-static --reset -p yes \
    || echo "Warning: could not register binfmt handlers (may already be registered)"

# Build the builder image
echo ">>> Building kiosk builder image..."
${DOCKER} build -f "${DIR}/Dockerfile.kiosk" -t kiosk-builder "${DIR}"

mkdir -p "${DIR}/work" "${DIR}/deploy"

for ARCH in ${ARCHES}; do
    echo ""
    echo "=================================================="
    echo "  Building for ARCH=${ARCH}"
    echo "=================================================="

    mkdir -p "${DIR}/work/${ARCH}" "${DIR}/deploy/${ARCH}"

    RUN_OPTS=(
        --rm
        --privileged
        -v /dev:/dev
        -v "${DIR}/work:/work"
        -v "${DIR}/deploy:/deploy"
        -e "ARCH=${ARCH}"
    )

    # Pass through optional config overrides
    for VAR in RELEASE MIRROR KIOSK_HOSTNAME ROOT_PASSWORD \
               KIOSK_LOCALE KIOSK_TIMEZONE IMAGE_SIZE; do
        [ -n "${!VAR:-}" ] && RUN_OPTS+=(-e "${VAR}=${!VAR}")
    done

    # Helper: should we (re-)run a stage?
    should_run() {
        local stage_num=$1
        local tarball="${DIR}/work/${ARCH}/stage${stage_num}.tar.gz"
        if [ -n "${FORCE_STAGE}" ] && [ "${stage_num}" -ge "${FORCE_STAGE}" ]; then
            echo "[${ARCH}] Stage ${stage_num}: forced rebuild"
            rm -f "${tarball}"
            return 0
        fi
        if [ ! -f "${tarball}" ]; then
            return 0
        fi
        echo "[${ARCH}] Stage ${stage_num}: skipping (tarball exists)"
        return 1
    }

    # Stage 0: Bootstrap
    if should_run 0; then
        echo "[${ARCH}] Stage 0: Bootstrap..."
        ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage0-bootstrap.sh
    fi

    # Stage 1: Packages
    if should_run 1; then
        echo "[${ARCH}] Stage 1: Installing packages..."
        ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage1-packages.sh
    fi

    # Stage 2: Configure
    if should_run 2; then
        echo "[${ARCH}] Stage 2: Configuring system..."
        ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage2-configure.sh
    fi

    # Stage 3: Create disk image (always runs to produce fresh image)
    echo "[${ARCH}] Stage 3: Creating disk image..."
    ${DOCKER} run "${RUN_OPTS[@]}" kiosk-builder /kiosk/stage3-image.sh

    echo "[${ARCH}] Done! Image in: deploy/${ARCH}/"
done

echo ""
echo "All builds complete."
ls -lh "${DIR}/deploy"/*/*

#!/bin/bash
# Host wrapper: turns a built unitotem-*-$ARCH.img.xz into a parts set (deploy/$ARCH/<name>.parts/) via the
# unitotem-parts-builder container (Dockerfile.parts, deploy/make-parts-image.sh). It prepares the scratch
# decompressed image and drives docker. unitotem/stage3-image.sh has its own optional MAKE_PARTS hook using the
# same library; this path regenerates a parts set from an existing .img.xz without rebuilding.
# Usage: ./deploy/make-parts.sh [--arch amd64|arm64] [--image PATH] [--out DIR] [--keep-scratch]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${DIR}/deploy/lib.sh"

require_cmd docker xz sha256sum

DOCKER="${DOCKER:-docker}"
OPT_ARCH="" OPT_IMAGE="" OPT_OUT="" OPT_KEEP_SCRATCH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)         OPT_ARCH="$2"; shift 2 ;;
        --image)        OPT_IMAGE="$2"; shift 2 ;;
        --out)          OPT_OUT="$2"; shift 2 ;;
        --keep-scratch) OPT_KEEP_SCRATCH=1; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

if [ -n "$OPT_IMAGE" ]; then
    IMAGE="$OPT_IMAGE"
    [ -n "$OPT_ARCH" ] || case "$IMAGE" in
        *-amd64.img.xz) OPT_ARCH=amd64 ;;
        *-arm64.img.xz) OPT_ARCH=arm64 ;;
        *) die "Cannot infer the architecture from $IMAGE, pass --arch" ;;
    esac
else
    [ -n "$OPT_ARCH" ] || die "--arch is required when --image is not given"
    IMAGE=$(ls -t "${DIR}/deploy/${OPT_ARCH}/unitotem-"*"-${OPT_ARCH}.img.xz" 2>/dev/null | head -1)
    [ -n "$IMAGE" ] || die "no image found for ${OPT_ARCH}"
fi
[ -f "$IMAGE" ] || die "image not found: $IMAGE"
ARCH="$OPT_ARCH"

SETNAME=$(basename "$IMAGE" .img.xz)
OUTDIR="${OPT_OUT:-${DIR}/deploy/${ARCH}/${SETNAME}.parts}"

log "Building the unitotem-parts-builder container image..."
${DOCKER} build -f "${DIR}/Dockerfile.parts" -t unitotem-parts-builder "${DIR}"

SCRATCH_DIR="${DIR}/work/parts-scratch.$$"
mkdir -p "$SCRATCH_DIR"
cleanup_scratch() {
    [ "$OPT_KEEP_SCRATCH" = 1 ] || rm -rf "$SCRATCH_DIR"
}
trap cleanup_scratch EXIT

log "Decompressing ${IMAGE} into ${SCRATCH_DIR} (sparse)..."
xz -dc "$IMAGE" | dd of="${SCRATCH_DIR}/$(basename "$IMAGE" .xz)" bs=4M conv=sparse status=progress

mkdir -p "${DIR}/deploy/${ARCH}"
# --out: the container writes the set below /out (the parent of OUTDIR on the host).
OUT_PARENT=$(dirname "$OUTDIR")
mkdir -p "$OUT_PARENT"
OUT_PARENT=$(cd "$OUT_PARENT" && pwd)
OUTDIR="${OUT_PARENT}/$(basename "$OUTDIR")"

log "Generating the parts set (${ARCH})..."
${DOCKER} run --rm --privileged \
    -v /dev:/dev \
    -v "${SCRATCH_DIR}:/scratch" \
    -v "${DIR}/deploy:/deploy" \
    -v "${OUT_PARENT}:/out" \
    unitotem-parts-builder \
    /parts/make-parts-image.sh \
        "/scratch/$(basename "$IMAGE" .xz)" "$ARCH" "$SETNAME" "$(basename "$IMAGE" .xz)" "/out/$(basename "$OUTDIR")"

log "Done: ${OUTDIR}"
ls -lh "${OUTDIR}"

#!/bin/bash
# Host wrapper: turns a built unitotem-*-$ARCH.img.xz into a parts set
# (deploy/$ARCH/<name>.parts/) via the unitotem-parts-builder container. See
# Dockerfile.parts/deploy/make-parts-image.sh for what actually happens
# inside; this script only prepares the scratch decompressed image and
# drives docker.
#
# Deliberately decoupled from the kiosk build itself (unitotem/stage3-image.sh
# has its own optional MAKE_PARTS hook that calls the same library against
# the loop device it already has attached, for when a fresh build is
# happening anyway) - the point of this standalone path is being able to
# regenerate a parts set from an *already-built* .img.xz without a 40-minute
# rebuild, since the parts format is expected to change a few times.
#
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
        *) die "Opzione sconosciuta: $1" ;;
    esac
done

if [ -n "$OPT_IMAGE" ]; then
    IMAGE="$OPT_IMAGE"
    [ -n "$OPT_ARCH" ] || case "$IMAGE" in
        *-amd64.img.xz) OPT_ARCH=amd64 ;;
        *-arm64.img.xz) OPT_ARCH=arm64 ;;
        *) die "Impossibile dedurre l'architettura da $IMAGE, specifica --arch" ;;
    esac
else
    [ -n "$OPT_ARCH" ] || die "--arch richiesto quando non si specifica --image"
    IMAGE=$(ls -t "${DIR}/deploy/${OPT_ARCH}/unitotem-"*"-${OPT_ARCH}.img.xz" 2>/dev/null | head -1)
    [ -n "$IMAGE" ] || die "nessuna immagine trovata per ${OPT_ARCH}"
fi
[ -f "$IMAGE" ] || die "immagine non trovata: $IMAGE"
ARCH="$OPT_ARCH"

SETNAME=$(basename "$IMAGE" .img.xz)
OUTDIR="${OPT_OUT:-${DIR}/deploy/${ARCH}/${SETNAME}.parts}"

log "Costruisco l'immagine del container unitotem-parts-builder..."
${DOCKER} build -f "${DIR}/Dockerfile.parts" -t unitotem-parts-builder "${DIR}"

SCRATCH_DIR="${DIR}/work/parts-scratch.$$"
mkdir -p "$SCRATCH_DIR"
cleanup_scratch() {
    [ "$OPT_KEEP_SCRATCH" = 1 ] || rm -rf "$SCRATCH_DIR"
}
trap cleanup_scratch EXIT

log "Decomprimo ${IMAGE} in ${SCRATCH_DIR} (sparse)..."
xz -dc "$IMAGE" | dd of="${SCRATCH_DIR}/$(basename "$IMAGE" .xz)" bs=4M conv=sparse status=progress

mkdir -p "${DIR}/deploy/${ARCH}"

log "Genero il parts set (${ARCH})..."
${DOCKER} run --rm --privileged \
    -v /dev:/dev \
    -v "${SCRATCH_DIR}:/scratch" \
    -v "${DIR}/deploy:/deploy" \
    unitotem-parts-builder \
    /parts/make-parts-image.sh \
        "/scratch/$(basename "$IMAGE" .xz)" "$ARCH" "$SETNAME" "$(basename "$IMAGE" .xz)"

log "Fatto: deploy/${ARCH}/${SETNAME}.parts/"
ls -lh "${OUTDIR}"

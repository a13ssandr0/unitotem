#!/bin/bash
# Runs INSIDE the unitotem-parts-builder container (see Dockerfile.parts and
# deploy/make-parts.sh). Attaches the scratch image file as a loop device
# and hands off to parts-lib.sh's make_parts() - see that file for the
# actual per-partition logic.
set -euo pipefail
source /parts/parts-lib.sh

SCRATCH_IMG="$1"
ARCH="$2"
SETNAME="$3"
SRCIMG_BASENAME="$4"

[ -f "$SCRATCH_IMG" ] || { echo "Scratch image not found: $SCRATCH_IMG" >&2; exit 1; }

OUTDIR="/deploy/${ARCH}/${SETNAME}.parts"
rm -rf "$OUTDIR"

LOOP=$(losetup --find --show --partscan --read-only "$SCRATCH_IMG")
echo "Loop device: ${LOOP}"

cleanup() {
    losetup -d "${LOOP}" 2>/dev/null || true
}
trap cleanup EXIT

make_parts "$LOOP" "$OUTDIR" "$ARCH" "$SETNAME" "/scratch/${SRCIMG_BASENAME}"

echo "=== Parts set complete: ${OUTDIR} ==="

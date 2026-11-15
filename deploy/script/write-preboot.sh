#!/bin/bash
# Builds the preboot card (the OTA fallback in recover mode, no password, no key) and writes it to an SD card. See make-preboot-image.sh and
# write-sd.sh; this runs one after the other on a temporary image.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { cat <<'USAGE'
Usage: write-preboot.sh --image FILE [--yes] [--out FILE] [DEVICE]

  --image FILE   arm64 image: firmware, recovery kernel and initrd
  DEVICE         whole disk of the card (default: the only removable one)
  --out FILE     keep the preboot image there
  --yes          do not ask

Needs root. The card's fallback needs no password.
Docs: docs/system/deploy-and-recovery.md
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$(id -u)" = 0 ] || exec sudo env "HOME=${HOME}" "TERM=${TERM:-xterm}" "${BASH}" "${BASH_SOURCE[0]}" "$@"
log() { printf '%s %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" "$2" >&2; }
die() { log ERROR "$1"; exit 1; }

YES=() IMG="" DEVICE="" OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=(--yes); shift ;;
        --image) IMG=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        -*) die "unknown option $1" ;;
        *) DEVICE=$1; shift ;;
    esac
done
[ -n "$IMG" ] || die "--image FILE is required (an arm64 image)"

if [ -z "$DEVICE" ]; then
    mapfile -t cands < <(lsblk -dnbo NAME,SIZE,RM,TYPE | awk '$3==1 && $4=="disk" && $2>0 {print "/dev/"$1}')
    case "${#cands[@]}" in
        0) die "no removable disk with a card in it: insert the card or name the device" ;;
        1) DEVICE=${cands[0]} ;;
        *) lsblk -o NAME,SIZE,MODEL,TRAN,RM "${cands[@]}" >&2; die "more than one removable disk: name the one to write" ;;
    esac
fi
# a card that was mounted by the desktop: its partitions are released first (only this device)
lsblk -lnpo NAME,MOUNTPOINT "$DEVICE" | awk 'NF==2{print $1}' | xargs -r umount

TMP=""
if [ -z "$OUT" ]; then TMP=$(mktemp -d "${UNITOTEM_TMPFS:-/dev/shm}/preboot.XXXXXX"); OUT="$TMP/unitotem-preboot-arm64.img"; fi
trap '[ -z "$TMP" ] || { rm -f -- "$TMP/unitotem-preboot-arm64.img" "$TMP/unitotem-preboot-arm64.img.xz"; rmdir -- "$TMP"; }' EXIT
log INFO "building the preboot image"
bash "${HERE}/make-preboot-image.sh" --image "$IMG" --out "$OUT"
log INFO "writing it to ${DEVICE}"
bash "${HERE}/write-sd.sh" "${YES[@]}" "${OUT}.xz" "$DEVICE"

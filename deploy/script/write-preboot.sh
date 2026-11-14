#!/bin/bash
# Builds the preboot SD image (the OTA fallback in recover mode, open access: no password, no key) and writes it to an SD card.
#
#   write-preboot.sh [--yes] [--image FILE] [--out FILE] [DEVICE]
#
#   DEVICE  whole disk of the card; without it the only removable disk with a medium is used (several: the list is shown and the script stops)
#   --image the arm64 image the firmware files are taken from (default: the newest in deploy/arm64)
#   --out   where the preboot image is made (default deploy/arm64/unitotem-preboot-arm64.img, with its .xz)
#
# The Raspberry Pi (3, 4 or 5) boots the card, gets an address by DHCP on its wired interface, shows it on the screen and waits for the host:
#   deploy/script/remote-deploy.sh recover <address> --image <full image> --yes      (with OTA_FALLBACK_OPEN=1)
# Runs as root: started as a user it asks sudo and runs again.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;; esac
[ "$(id -u)" = 0 ] || exec sudo env "HOME=${HOME}" "TERM=${TERM:-xterm}" "${BASH}" "${BASH_SOURCE[0]}" "$@"
log() { printf '%s %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$1" "$2" >&2; }
die() { log ERROR "$1"; exit 1; }

YES=() IMG=() DEVICE="" OUT="${DIR}/deploy/arm64/unitotem-preboot-arm64.img"
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=(--yes); shift ;;
        --image) IMG=(--image "$2"); shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        -*) die "unknown option $1" ;;
        *) DEVICE=$1; shift ;;
    esac
done

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
log INFO "building the preboot image"
bash "${DIR}/deploy/script/make-preboot-image.sh" "${IMG[@]}" --out "$OUT"
log INFO "writing ${OUT}.xz to ${DEVICE}"
bash "${DIR}/deploy/script/write-sd.sh" "${YES[@]}" "${OUT}.xz" "$DEVICE"

#!/bin/bash
# Minimal "preboot" SD image for a Raspberry Pi (arm64): the OTA fallback and nothing else.
#
# One FAT partition (MBR, type 0c, from 1 MiB) holding the boot tree (unitotem/make-boot-tree.sh): the Pi firmware, the recovery kernel
# (recovery8.img) and initrd (with the repository's engine), the device trees, config.txt and cmdline.txt (unitotem.ota=recover). The
# tree is built once per build (--tree, default build/arm64/boot-tree); --image FILE extracts the same files from the FIRMWARE partition
# of an arm64 image. The Pi boots it, gets an address by DHCP, shows it and waits for `remote-deploy.sh deploy <address> --image FILE`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { cat <<'USAGE'
Usage: make-preboot-image.sh [--tree DIR | --image FILE] [options]

  --tree DIR        boot tree of the arm64 build (default: build/arm64/boot-tree when it exists)
  --image FILE      arm64 image: its FIRMWARE partition is turned into a boot tree (needs root)
  --out FILE        result (./unitotem-preboot-arm64.img)
  --engine FILE     engine put in the initrd of --image (ota-engine.sh beside this)
  --size-mib N      card image size (128)
  --no-xz           no .xz copy

Needs root. Docs: docs/system/build.md
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
# Runs this script again as root through sudo, with the variables it reads (sudo-rs ignores -E): the OTA_* credentials, UNITOTEM_*,
# the state directory, the ssh agent and the locale. sudo keeps the working directory.
reexec_as_root() {
    local v vars=("HOME=${HOME}")
    for v in $(compgen -e); do
        case "$v" in OTA_*|UNITOTEM_*|XDG_STATE_HOME|SSH_AUTH_SOCK|SSHPASS|TERM|LANG|LC_*|TMPDIR) vars+=("${v}=${!v}") ;; esac
    done
    exec sudo env "${vars[@]}" "${BASH}" "$@"
}
[ "$(id -u)" = 0 ] || reexec_as_root "${BASH_SOURCE[0]}" "$@"
ARCH=arm64
IMAGE="" TREE="" ENGINE="${HERE}/ota-engine.sh" ENGINE_SET=0 OUT="./unitotem-preboot-arm64.img" SIZE_MIB=128 XZ=1
DEFAULT_TREE="${HERE}/../../build/arm64/boot-tree"
die() { echo "$1" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --tree) TREE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --engine) ENGINE="$2"; ENGINE_SET=1; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --size-mib) SIZE_MIB="$2"; shift 2 ;;
        --no-xz) XZ=0; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
for c in sfdisk mkfs.fat dd tar xz truncate install cpio sha256sum mount; do command -v "$c" >/dev/null || { echo "missing command $c" >&2; exit 1; }; done
source "${HERE}/image-lib.sh"
if [ -n "$IMAGE" ] && [ -n "$TREE" ]; then die "give --tree DIR or --image FILE, not both"; fi
if [ -z "$IMAGE" ] && [ -z "$TREE" ]; then
    [ -f "${DEFAULT_TREE}/boot-tree.sha256" ] || die "--tree DIR or --image FILE is required (no ${DEFAULT_TREE})"
    TREE="$DEFAULT_TREE"
fi
if [ "$ENGINE_SET" = 1 ] && [ -z "$IMAGE" ]; then die "--engine applies to --image only: the tree carries its engine"; fi
[ -z "$IMAGE" ] || [ -f "$IMAGE" ] || die "image not found: $IMAGE"
[ -z "$IMAGE" ] || [ -f "$ENGINE" ] || die "engine not found: $ENGINE"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/preboot.XXXXXX")
trap 'umount -l "$WORK/mnt" 2>/dev/null || true; image_close; rm -rf -- "$WORK"' EXIT
FW="$WORK/fw"; mkdir -p "$FW"

if [ -n "$IMAGE" ]; then
    # the FIRMWARE partition of the image: its top-level files are the input of the boot tree
    image_open "$IMAGE" || die "cannot open $IMAGE"
    # FIRMWARE found by its filesystem label (p1 of the arm64 image, MBR; the table kind does not matter)
    FWNODE=""; for n in 1 2; do d=$(image_node "$n") && [ "$(blkid -s LABEL -o value "$d")" = FIRMWARE ] && FWNODE=$d && break; done
    [ -n "$FWNODE" ] || die "the image has no FIRMWARE partition"
    SRC="$WORK/src"; mkdir -p "$SRC" "$WORK/fwsrc"; mount -t vfat -o ro "$FWNODE" "$SRC"
    find "$SRC" -mindepth 1 -maxdepth 1 -type f -exec cp -- {} "$WORK/fwsrc/" \;
    LEVEL=$(sed -n 's/^# unitotem-recovery-level: //p' "$SRC/recovery.sha256" | head -n 1)
    umount "$SRC"
    image_close
    [ -s "$WORK/fwsrc/recovery8.img" ] && [ -s "$WORK/fwsrc/recovery-initrd.img" ] \
        || die "the image has no recovery8.img and recovery-initrd.img on its boot partition"
    # the firmware version is the one the image recorded (unitotem-firmware.json)
    FWVER=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$WORK/fwsrc/unitotem-firmware.json") \
        || die "the image has no readable unitotem-firmware.json on its boot partition"
    bash "${HERE}/../../unitotem/make-boot-tree.sh" --firmware "$WORK/fwsrc" --firmware-version "$FWVER" \
        --recovery-vmlinuz "$WORK/fwsrc/recovery8.img" --recovery-initrd "$WORK/fwsrc/recovery-initrd.img" \
        --level "$LEVEL" --engine "$ENGINE" --out "$WORK/tree"
    TREE="$WORK/tree"
fi

# The card carries the tree as it is: every file checked against its manifest first.
[ -f "$TREE/boot-tree.sha256" ] || die "$TREE: no boot-tree.sha256 (build the tree with unitotem/make-boot-tree.sh)"
( cd "$TREE" && sha256sum -c --quiet boot-tree.sha256 ) || die "$TREE: a file does not match boot-tree.sha256"
cp -a -- "$TREE"/. "$FW"/
CONTENT_KB=$(du -sk "$FW" | cut -f1)
[ $((SIZE_MIB * 1024)) -gt $((CONTENT_KB + 8192)) ] || die "content is ${CONTENT_KB} KiB: a larger --size-mib is needed"

# FAT32 partition from 1 MiB to the end (MBR: the firmware of every Pi reads it; FAT32 needs >= ~33 MiB)
FAT_MIB=$((SIZE_MIB - 1))
rm -f -- "$OUT"; truncate -s "${SIZE_MIB}M" "$OUT"
printf 'label: dos\nunit: sectors\n\nstart=2048, size=%d, type=c, bootable\n' $((FAT_MIB * 2048)) | sfdisk -q "$OUT"
truncate -s "${FAT_MIB}M" "$WORK/fat.img"
mkfs.fat -F32 -n FIRMWARE -i 50524550 "$WORK/fat.img" >/dev/null
mkdir -p "$WORK/mnt"
mount -o loop -- "$WORK/fat.img" "$WORK/mnt"
cp -r -- "$FW"/. "$WORK/mnt"/
sync
umount "$WORK/mnt"
dd if="$WORK/fat.img" of="$OUT" bs=1M seek=1 conv=notrunc status=none
echo ">>> ${OUT}: $(du -h --apparent-size "$OUT" | cut -f1), content ${CONTENT_KB} KiB, tree ${TREE}"
if [ "$XZ" = 1 ]; then
    xz -T0 -f -k -- "$OUT"
    echo ">>> ${OUT}.xz: $(du -h "${OUT}.xz" | cut -f1)"
fi

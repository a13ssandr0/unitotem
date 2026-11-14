#!/bin/bash
# Test fixture for the loopback harness of the OTA engine (work/loopback-test): the descriptor of an image and one stream file per partition
# in a directory, the shape the harness feeds to the engine's restore-part. The deploy itself reads the image in place and writes nothing
# (deploy/script/image-lib.sh).
#   tools/release/image-streams.sh IMAGE OUTDIR [ARCH]      (root)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
[ $# -ge 2 ] || { echo "usage: $0 IMAGE OUTDIR [ARCH]" >&2; exit 1; }
IMAGE=$1 OUT=$2 ARCH=${3:-amd64}
source "${DIR}/deploy/script/image-lib.sh"
trap image_close EXIT
image_open "$IMAGE"
image_describe "$OUT" "$ARCH"
n=""
while IFS= read -r line; do
    case "$line" in
        UNITOTEM_PART=*) n=${line#*=} ;;
        UNITOTEM_PART_ACTION=restore|UNITOTEM_PART_ACTION=raw)
            label=$(awk -F= -v n="$n" '/^UNITOTEM_PART=/{c=$2} c==n && /^UNITOTEM_PART_LABEL=/{print $2; exit}' "$OUT/parts.manifest")
            f="p${n}-${label}.pc.xz"; image_stream "$n" > "$OUT/$f"
            sed -i "/^UNITOTEM_PART=${n}\$/,/^\$/ s#^UNITOTEM_PART_COMP=xz\$#UNITOTEM_PART_STREAM_FILE=${f}\nUNITOTEM_PART_COMP=xz#" "$OUT/parts.manifest" ;;
    esac
done < "$OUT/parts.manifest"
echo "$OUT: descriptor and streams of $(basename "$IMAGE")"

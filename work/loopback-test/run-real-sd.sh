#!/bin/bash
# §11.4 step 2: run the OTA stage1+stage2 sequence against the real Pi SD
# card (/dev/sdb), scoped to exactly that device's major:minor (8:16 for
# the disk, 8:17-8:19 for its 3 partitions) - NOT --privileged, and NOT a
# blanket major-8 rule, because this host also has /dev/sdc (a real 3.6TB
# drive) on the same major number that must stay completely inaccessible.
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARTS_DIR="${1:?uso: run-real-sd.sh <path ai .parts>}"
[ -d "$PARTS_DIR" ] || { echo "non trovato: $PARTS_DIR" >&2; exit 1; }
PARTS_DIR="$(cd "$PARTS_DIR" && pwd)"

docker run --rm \
    --cap-add SYS_ADMIN --cap-add MKNOD --cap-add DAC_OVERRIDE \
    --device /dev/sdb:/dev/sdb \
    --device-cgroup-rule='b 8:16 rwm' \
    --device-cgroup-rule='b 8:17 rwm' \
    --device-cgroup-rule='b 8:18 rwm' \
    --device-cgroup-rule='b 8:19 rwm' \
    --security-opt apparmor=unconfined \
    -v "${DIR}:/repo:ro" \
    -v "${PARTS_DIR}:/work/parts:ro" \
    -v "${DIR}/work/loopback-test:/work/driver:ro" \
    -v "${DIR}/work/loopback-test/scratch-real-sd:/work" \
    --workdir /work \
    debian:bookworm \
    bash /work/driver/inside-real-sd.sh

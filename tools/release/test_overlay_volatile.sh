#!/bin/bash
# Test of the volatile overlays (unitotem/files/overlayfs-hook.sh: volatile_overlays): with no usable DATA the hook
# must leave ROOT writable on a tmpfs. Needs docker with --privileged (tmpfs, overlay and bind mounts happen only
# INSIDE the container, removed with it). Uses the local debian:trixie image (no pull).
#   tools/release/test_overlay_volatile.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc=0
docker run --rm --name overlay-volatile-test --privileged --pull never \
    -v "${DIR}:/repo:ro" --workdir /tmp debian:trixie \
    bash /repo/tools/release/test_overlay_volatile_inside.sh || rc=$?
exit "$rc"

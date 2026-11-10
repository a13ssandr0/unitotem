#!/bin/bash
# unitotem-persist-paths without DATA: /home becomes a writable tmpfs (container, root; uses real mounts).
# Run: docker run --rm --privileged -v "$PWD":/r:ro debian:trixie bash /r/tools/release/test_persist_volatile.sh
set -u
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
S=/r/unitotem/files/unitotem-persist-paths
[ -f "$S" ] || S="$(dirname "$0")/../../unitotem/files/unitotem-persist-paths"
mkdir -p /home /mnt/data
if mountpoint -q /mnt/data; then bad "/mnt/data is a mountpoint in the test setup"; fi
bash "$S" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "script exits 0 without DATA" || bad "exit status $rc"
mountpoint -q /home && ok "/home is a mount point" || bad "/home is not mounted"
findmnt -n -o FSTYPE /home | grep -qx tmpfs && ok "/home is tmpfs" || bad "/home is not tmpfs"
mkdir /home/admin 2>/dev/null && ok "an account home can be created" || bad "cannot create a home"
bash "$S" 2>/dev/null; [ "$(findmnt -n -o FSTYPE /home | wc -l)" = 1 ] && ok "second run does not stack mounts" || bad "mounts stacked"
exit $fail

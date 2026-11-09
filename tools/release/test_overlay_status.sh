#!/bin/sh
# Runs the init-bottom overlay hook under dash with mocked blkid, mount, e2fsck, udevadm, sleep, tune2fs and
# dumpe2fs in a temporary directory. Checks the one-line status file, the log prefix and the record on DATA.
# No block device, mount or real system file is touched. Usage: dash tools/release/test_overlay_status.sh
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
SRC="$HERE/unitotem/files/overlayfs-hook.sh"
TMPBASE=${TMPDIR:-/tmp}
T=$(mktemp -d "$TMPBASE/overlay-status.XXXXXX") || exit 1
cleanup() {
    case "$T" in
        "$TMPBASE"/overlay-status.*) rm -rf -- "$T" ;;
    esac
}
trap cleanup EXIT
trap 'exit 1' INT TERM

mkdir -p "$T/bin"
# Mocks: DATA is found only when MOCK_DATA is set; MOCK_FAIL names the one mount that fails.
cat > "$T/bin/blkid" <<'EOF'
#!/bin/sh
[ "$1" = -L ] && [ "$2" = DATA ] && [ -n "${MOCK_DATA:-}" ] && { echo "$MOCK_DATA"; exit 0; }
exit 2
EOF
cat > "$T/bin/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$MOCK_LOG"
case "$*" in
    *"-t ext4"*) [ "${MOCK_FAIL:-}" = data ] && exit 1 ;;
    *"-t tmpfs"*) [ "${MOCK_FAIL:-}" = tmpfs ] && exit 1 ;;
    *"lowerdir=$MOCK_ROOT/etc,"*) [ "${MOCK_FAIL:-}" = etc ] && exit 1 ;;
    *" $MOCK_ROOT/var/lib/dpkg") [ "${MOCK_FAIL:-}" = dpkg ] && exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/dumpe2fs" <<'EOF'
#!/bin/sh
echo "Filesystem features: has_journal"
exit 0
EOF
for t in udevadm sleep e2fsck tune2fs; do
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/$t"
done
cat > "$T/bin/umount" <<'EOF'
#!/bin/sh
echo "umount $*" >> "$MOCK_LOG"
exit 0
EOF
chmod +x "$T/bin/"*

# The hook reads its helpers from /scripts/functions (initramfs): a copy points that at a mock.
cat > "$T/functions" <<'EOF'
log_warning_msg() { echo "W: $*" >> "$MOCK_LOG"; }
log_success_msg() { echo "I: $*" >> "$MOCK_LOG"; }
EOF
sed -e "s|/scripts/functions|$T/functions|" "$SRC" > "$T/hook.sh"

pass=0; failn=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { failn=$((failn + 1)); echo "FAIL: $1"; }

# run_case NAME DATA FAIL: runs the hook in its own directory $T/NAME; sets C, RC.
run_case() {
    C="$T/$1"
    mkdir -p "$C/root/etc" "$C/root/var/lib/dpkg" "$C/root/root" "$C/root/var" "$C/root/mnt/data" "$C/run"
    env PATH="$T/bin:$PATH" MOCK_LOG="$C/log" MOCK_ROOT="$C/root" MOCK_DATA="$2" MOCK_FAIL="$3" \
        UNITOTEM_OVERLAY_STATUS="$C/run/unitotem-overlay.status" UNITOTEM_VOLATILE_DIR="$C/volatile" rootmnt="$C/root" \
        dash "$T/hook.sh" > "$C/stdout" 2>&1
    RC=$?
}
status_is() { [ -f "$C/run/unitotem-overlay.status" ] && [ "$(cat "$C/run/unitotem-overlay.status")" = "$1" ]; }
one_line() { [ "$(wc -l < "$C/run/unitotem-overlay.status")" -eq 1 ]; }
logged() { grep -q "$1" "$C/log"; }

# 1. DATA mounted, every overlay and the dpkg pin fine: ok; a stale status from an earlier run is replaced.
mkdir -p "$T/ok/run"; echo "failed:stale" > "$T/ok/run/unitotem-overlay.status"
run_case ok /dev/mockdata none
[ "$RC" -eq 0 ] && ok "ok: exit 0" || bad "ok: exit $RC"
status_is ok && ok "ok: status file is ok" || bad "ok: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
one_line && ok "ok: status file has one line" || bad "ok: status file is not one line"
logged "^I: overlay: status ok$" && ok "ok: log line with overlay: prefix" || bad "ok: no log line"
grep -qx "overlay-status=ok" "$C/root/mnt/data/.unitotem-overlay-status" \
    && ok "ok: DATA record carries overlay-status=ok" || bad "ok: DATA record without overlay-status=ok"

# volatile_checks NAME: the no-DATA and data-mount cases share the volatile path: tmpfs of 32..128 MiB, overlays of
# etc, root and var on it, no DATA record, the tmpfs released, one status line.
volatile_checks() {
    vsz=$(sed -n 's/^mount -t tmpfs -o size=\([0-9][0-9]*\)m,.*/\1/p' "$C/log" | head -n 1)
    [ -n "$vsz" ] && [ "$vsz" -ge 32 ] && [ "$vsz" -le 128 ] \
        && ok "$1: tmpfs size ${vsz} MiB (32..128)" || bad "$1: tmpfs size '$vsz' not in 32..128"
    grep -q "^mount -t tmpfs -o size=[0-9]*m,mode=0755 tmpfs $C/volatile\$" "$C/log" \
        && ok "$1: tmpfs mounted on the volatile dir" || bad "$1: no tmpfs mount on the volatile dir"
    for d in etc root var; do
        grep -q "lowerdir=$C/root/$d,upperdir=$C/volatile/upper/$d,workdir=$C/volatile/work/$d $C/root/$d\$" "$C/log" \
            && ok "$1: overlay of /$d on the tmpfs" || bad "$1: no overlay of /$d on the tmpfs"
    done
    grep -q "^umount $C/volatile\$" "$C/log" && ok "$1: volatile dir released" || bad "$1: volatile dir not released"
    ! grep -q "$C/root/mnt/data/\(upper\|work\|\.dpkg-lower\)" "$C/log" && ! [ -e "$C/root/mnt/data/.unitotem-overlay-status" ] \
        && ok "$1: no DATA record, no DATA overlay" || bad "$1: DATA touched"
    one_line && ok "$1: status file has one line" || bad "$1: status file is not one line"
}

# 2. No DATA partition: volatile overlays (tmpfs), status volatile:no-data.
run_case nodata "" none
[ "$RC" -eq 0 ] && ok "no-data: exit 0" || bad "no-data: exit $RC"
status_is volatile:no-data && ok "no-data: status file is volatile:no-data" || bad "no-data: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
logged "^W: overlay: status volatile:no-data$" && ok "no-data: log line with overlay: prefix" || bad "no-data: no log line"
volatile_checks no-data

# 3. DATA found but not mountable: volatile overlays, status volatile:data-mount.
run_case datafail /dev/mockdata data
[ "$RC" -eq 0 ] && ok "data-mount: exit 0" || bad "data-mount: exit $RC"
status_is volatile:data-mount && ok "data-mount: status file is volatile:data-mount" || bad "data-mount: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
logged "^W: overlay: status volatile:data-mount$" && ok "data-mount: log line with overlay: prefix" || bad "data-mount: no log line"
volatile_checks data-mount

# 3b. No DATA and the tmpfs cannot be mounted: failed:volatile, no overlay, exit 0.
run_case tmpfsfail "" tmpfs
[ "$RC" -eq 0 ] && ok "tmpfs-fail: exit 0" || bad "tmpfs-fail: exit $RC"
status_is failed:volatile && ok "tmpfs-fail: status file is failed:volatile" || bad "tmpfs-fail: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
! logged "lowerdir=" && ok "tmpfs-fail: no overlay attempted" || bad "tmpfs-fail: overlay mount attempted"

# 3c. No DATA and one volatile overlay fails: failed:volatile, the tmpfs is still released.
run_case volfail "" etc
status_is failed:volatile && ok "volatile-overlay-fail: status file is failed:volatile" || bad "volatile-overlay-fail: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
grep -q "^umount $C/volatile\$" "$C/log" && ok "volatile-overlay-fail: volatile dir released" || bad "volatile-overlay-fail: volatile dir not released"

# 4. One overlay fails: status names it, the other overlays are still mounted.
run_case etcfail /dev/mockdata etc
[ "$RC" -eq 0 ] && ok "overlay-etc: exit 0" || bad "overlay-etc: exit $RC"
status_is failed:overlay-etc && ok "overlay-etc: status file is failed:overlay-etc" || bad "overlay-etc: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
logged "var,upperdir" && ok "overlay-etc: /var overlay still attempted" || bad "overlay-etc: /var overlay not attempted"
logged "^W: overlay: /etc failed$" && ok "overlay-etc: log line with overlay: prefix" || bad "overlay-etc: no log line"

# 5. dpkg pin fails after the overlays: status failed:dpkg-pin.
run_case dpkgfail /dev/mockdata dpkg
status_is failed:dpkg-pin && ok "dpkg-pin: status file is failed:dpkg-pin" || bad "dpkg-pin: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
logged "^W: overlay: status failed:dpkg-pin$" && ok "dpkg-pin: log line with overlay: prefix" || bad "dpkg-pin: no log line"

echo "RESULT: $pass passed, $failn failed"
[ "$failn" -eq 0 ]

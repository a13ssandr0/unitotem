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
        UNITOTEM_OVERLAY_STATUS="$C/run/unitotem-overlay.status" rootmnt="$C/root" \
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

# 2. No DATA partition: boot continues with no overlays, status no-data.
run_case nodata "" none
[ "$RC" -eq 0 ] && ok "no-data: exit 0" || bad "no-data: exit $RC"
status_is no-data && ok "no-data: status file is no-data" || bad "no-data: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
logged "^W: overlay: status no-data$" && ok "no-data: log line with overlay: prefix" || bad "no-data: no log line"
! logged "lowerdir=" && ok "no-data: no overlay mounted" || bad "no-data: overlay mount attempted"

# 3. DATA found but not mountable: status failed:data-mount, no overlays.
run_case datafail /dev/mockdata data
[ "$RC" -eq 0 ] && ok "data-mount: exit 0" || bad "data-mount: exit $RC"
status_is failed:data-mount && ok "data-mount: status file is failed:data-mount" || bad "data-mount: status file is '$(cat "$C/run/unitotem-overlay.status" 2>/dev/null)'"
one_line && ok "data-mount: status file has one line" || bad "data-mount: status file is not one line"

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

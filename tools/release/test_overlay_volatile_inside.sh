#!/bin/bash
# Runs INSIDE the privileged container of test_overlay_volatile.sh. The REAL hook runs under dash with the REAL
# mount and umount on a fake ROOT in a tmpfs. Only blkid (DATA lookup) and the /scripts/functions helpers are
# replaced. Nothing outside the container is touched.
set -uo pipefail
SRC=/repo/unitotem/files/overlayfs-hook.sh
HOOK=/tmp/volatile-hook.sh
FUNCS=/tmp/volatile-functions
LOGF=/tmp/volatile-log
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { failn=$((failn+1)); echo "FAIL: $1"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# Every mount under /fake and /volatile, deepest first, then the directories.
unmount_all() {
    awk '$2 ~ /^\/fake/ || $2 ~ /^\/volatile/ {print $2}' /proc/mounts | sort -r | while read -r m; do
        umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
    done
    rmdir /volatile 2>/dev/null
}
cleanup() { unmount_all; umount /fake 2>/dev/null; }
trap cleanup EXIT
trap 'exit 1' TERM INT

# blkid: DATA is found only when MOCK_DATA is set (it names the device); everything else finds nothing.
mkdir -p /work-bin
cat > /work-bin/blkid <<'EOF'
#!/bin/sh
[ "$1" = -L ] && [ "$2" = DATA ] && [ -n "${MOCK_DATA:-}" ] && { echo "$MOCK_DATA"; exit 0; }
exit 2
EOF
chmod +x /work-bin/blkid
# The hook's helpers: logged to a file, as the initramfs ones would be on the console.
cat > "$FUNCS" <<'EOF'
log_warning_msg() { echo "W: $*" >> "$UNITOTEM_LOG"; }
log_success_msg() { echo "I: $*" >> "$UNITOTEM_LOG"; }
EOF
sed "s|/scripts/functions|$FUNCS|" "$SRC" > "$HOOK"

# A fake ROOT: the directories the hook overlays and a dpkg database that must stay ROOT's.
make_tree() {  # make_tree DIR
    mkdir -p "$1/etc" "$1/root" "$1/var/lib/dpkg/info" "$1/mnt/data" "$1/run"
    echo "root:x:0:0:root:/root:/bin/sh" > "$1/etc/passwd"
    echo "Package: base-files" > "$1/var/lib/dpkg/status"
    echo "Package: bash" > "$1/var/lib/dpkg/info/bash.list"
}

# run_hook ROOT STATUS DATA: runs the hook with rootmnt=ROOT; DATA empty means no DATA partition. Sets RC.
run_hook() {
    : > "$LOGF"
    env PATH=/work-bin:$PATH MOCK_DATA="$3" UNITOTEM_LOG="$LOGF" UNITOTEM_OVERLAY_STATUS="$2" rootmnt="$1" \
        dash "$HOOK" > "$1.stdout" 2>&1
    RC=$?
}
status_is() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
writable() { echo "$2" > "$1/unitotem-writable-probe" && grep -qx "$2" "$1/unitotem-writable-probe"; }
overlay_on() { grep -q " $1 overlay " /proc/mounts; }

mkdir -p /fake
mount -t tmpfs -o size=256m tmpfs /fake || { echo "cannot mount the fake root tmpfs"; exit 1; }

# Case 1: no DATA partition. Case 2: DATA present, its ext4 mount fails (a zeroed image).
dd if=/dev/zero of=/tmp/nofs.img bs=1M count=64 2>/dev/null
mkdir -p /tmp/nofs-probe
mount -t ext4 /tmp/nofs.img /tmp/nofs-probe 2>/dev/null \
    && { echo "precondition failed: the zeroed image mounts"; exit 1; }

volatile_case() {  # volatile_case NAME STATUS DATA
    local name=$1 want=$2 data=$3 root=/fake/$1 st=/fake/$1-status
    echo "=== $name (expect $want)"
    make_tree "$root"
    cp -a "$root/var/lib/dpkg" "/fake/$1-dpkg-before"
    # ROOT read-only, as on the device: the incident was a read-only root with no overlays
    mount --bind "$root" "$root" && mount -o remount,bind,ro "$root" \
        || { bad "$name: cannot make the fake root read-only"; return 0; }
    chk "$name: ROOT is read-only before the hook" bash -c "! : > '$root/etc/unitotem-precheck' 2>/dev/null"
    chk "$name: no /volatile mount before the hook" bash -c '! grep -q " /volatile " /proc/mounts'
    run_hook "$root" "$st" "$data"
    sed 's/^/    log: /' "$LOGF"
    chk "$name: hook exit 0" [ "$RC" -eq 0 ]
    chk "$name: status is $want" status_is "$st" "$want"
    chk "$name: status file has one line" [ "$(wc -l < "$st")" -eq 1 ]
    for d in etc root var; do
        chk "$name: /$d is an overlay" overlay_on "$root/$d"
        chk "$name: /$d upper is on the volatile tmpfs" bash -c "grep ' $root/$d overlay ' /proc/mounts | grep -q 'upperdir=/volatile/upper/$d,'"
        chk "$name: /$d writable" writable "$root/$d" "$name-$d"
    done
    # a new write to /etc after the hook: the overlay keeps the tmpfs upper alive although /volatile is unmounted
    echo "survives umount of /volatile" > "$root/etc/unitotem-volatile-probe"
    chk "$name: write to /etc reads back after the hook" grep -qx "survives umount of /volatile" "$root/etc/unitotem-volatile-probe"
    chk "$name: /volatile is not mounted (released after the overlays)" bash -c '! grep -q " /volatile " /proc/mounts'
    chk "$name: no DATA record written" bash -c "[ ! -e '$root/mnt/data/.unitotem-overlay-status' ]"
    chk "$name: nothing mounted on /mnt/data" bash -c "! grep -q ' $root/mnt/data ' /proc/mounts"
    chk "$name: no write landed under /mnt/data" bash -c "[ -z \"\$(ls -A '$root/mnt/data')\" ]"
    chk "$name: /var/lib/dpkg content equals the lower" diff -r "$root/var/lib/dpkg" "/fake/$1-dpkg-before"
    chk "$name: /var/lib/dpkg pinned to ROOT (bind visible)" bash -c "grep -q ' $root/var/lib/dpkg ' /proc/mounts"
    chk "$name: dpkg stash released" bash -c '! grep -q "/volatile/.dpkg-lower" /proc/mounts'
    # the probe written to /etc is in the volatile upper only, not in the ROOT lower behind the overlay
    chk "$name: no leftover stash directory on ROOT" bash -c "[ ! -e '$root/mnt/data/.dpkg-lower' ]"
}

volatile_case nodata volatile:no-data ""
volatile_case datafail volatile:data-mount /tmp/nofs.img

# volatile_size against /proc/meminfo: MemTotal / 8192, clamped to 32..128 (container sees the host RAM).
kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
want=$((kb / 8192)); [ "$want" -ge 32 ] || want=32; [ "$want" -le 128 ] || want=128
got=$(UNITOTEM_SOURCE_ONLY=1 dash -c ". $HOOK; volatile_size")
chk "volatile_size: ${got} MiB = MemTotal/8192 clamped (${want})" [ "$got" = "$want" ]

echo "RESULT: $pass passed, $failn failed"
[ "$failn" -eq 0 ]

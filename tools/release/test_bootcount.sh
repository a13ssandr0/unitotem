#!/bin/bash
# Tests of the boot counter gate (bootcount_gate, deploy/ota-engine.sh) and of the fallback credentials without DATA
# (fallback_auth_setup). Fixtures only: every path is a tmp dir; mount, umount, mountpoint, blkid, sync, the log
# functions and cmd_serve_fallback are stubs. The cmdline is read from a fixture file.
#   bash tools/release/test_bootcount.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENGINE="$HERE/../../deploy/ota-engine.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/unitotem-bootcount-test.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# shellcheck disable=SC1090
. "$ENGINE"
set +e +u

# ---- stubs: defined after the engine is sourced, since sourcing defines the real log, warn, kmsg,
# cmd_serve_fallback, cmdline_get, check_flag_file, ab_failover and check_root_readonly ----
MOUNT_CALLS=(); UMOUNT_CALLS=(); SERVE_CALLS=(); LOGS=(); WARNS=(); FAILOVER_CALLS=0
TEST_MOUNTED=1; TEST_HAVE_ROOT=1; TEST_CMDLINE=""
mount()             { MOUNT_CALLS+=("$*"); return 0; }
umount()            { UMOUNT_CALLS+=("$*"); return 0; }
mountpoint()        { [ "${TEST_MOUNTED:-1}" = 1 ]; }
sync()              { :; }
sleep()             { :; }
udevadm()           { return 0; }
modprobe()          { return 0; }
kmsg()              { :; }
log()               { LOGS+=("$*"); }
warn()              { WARNS+=("$*"); }
check_flag_file()   { return 1; }
check_root_readonly() { return 0; }
ab_failover()      { FAILOVER_CALLS=$((FAILOVER_CALLS + 1)); return 1; }
cmd_serve_fallback() { SERVE_CALLS+=("$*"); return 0; }
# blkid -L LABEL: ROOT exists only when TEST_HAVE_ROOT=1; DATA, FIRMWARE and EFI never exist.
blkid() {
    if [ "${TEST_HAVE_ROOT:-0}" = 1 ] && [ "${2:-}" = ROOT ]; then echo /dev/fixture-root; return 0; fi
    return 2
}
# Same contract as the engine's cmdline_get, read from $TEST_CMDLINE.
cmdline_get() {
    local tok; local -a toks=()
    read -ra toks < "$TEST_CMDLINE" || true
    for tok in "${toks[@]}"; do
        case "$tok" in "$1="*) printf '%s\n' "${tok#*=}"; return 0 ;; esac
    done
    return 1
}

PASS=0; FAIL=0
expect() {   # expect NAME COMMAND...: counts PASS or FAIL
    local name="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); echo "PASS: $name"
    else FAIL=$((FAIL + 1)); echo "FAIL: $name"; fi
}

BFILE=""
new_case() {   # new_case NAME [CMDLINE]: fresh boot FAT directory and empty call logs
    local dir="$TMP/$1"
    mkdir -p "$dir/boot"
    OTA_BOOTFS_MNT="$dir/boot"
    BFILE="$OTA_BOOTFS_MNT/unitotem-ota.bootcount"
    TEST_CMDLINE="$dir/cmdline"
    printf '%s\n' "${2:-root=LABEL=ROOT ro quiet unitotem.slot=a}" > "$TEST_CMDLINE"
    MOUNT_CALLS=(); UMOUNT_CALLS=(); SERVE_CALLS=(); LOGS=(); WARNS=(); FAILOVER_CALLS=0
    TEST_MOUNTED=1; TEST_HAVE_ROOT=1; BOOTCOUNT_RECOVERY=0
}

GATE_RC=0; RECOVERY=0
boot() {   # one pass through the gate
    bootcount_gate; GATE_RC=$?; RECOVERY=$BOOTCOUNT_RECOVERY
}

# file_is N: the file holds exactly "N\n" (two bytes)
file_is() { [ "$(cat "$BFILE" 2>/dev/null)" = "$1" ] && [ "$(stat -c %s "$BFILE" 2>/dev/null)" = 2 ]; }
inode_of() { stat -c %i "$BFILE"; }
serve_reason_ok() {
    [ "${SERVE_CALLS[0]:-}" = "--reason three consecutive boots without a healthy manager --kind recovery --idle-timeout 21600" ]
}
contains_umount() {
    local x; for x in "${UMOUNT_CALLS[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1
}

# ---- 1. sequence on the A/B layout (unitotem.slot=a on the command line) ----
new_case ab
boot; expect "A/B boot 1 proceeds" [ "$RECOVERY" = 0 ]
expect "A/B boot 1 creates the file with 1" file_is 1
boot; expect "A/B boot 2 proceeds" [ "$RECOVERY" = 0 ]
expect "A/B boot 2 writes 2" file_is 2
boot; expect "A/B boot 3 proceeds" [ "$RECOVERY" = 0 ]
expect "A/B boot 3 writes 3" file_is 3
boot
expect "A/B boot 4 enters the fallback" [ "$RECOVERY" = 1 ]
expect "A/B boot 4 gate returns 0" [ "$GATE_RC" = 0 ]
expect "A/B boot 4 serve-fallback called once" [ "${#SERVE_CALLS[@]}" = 1 ]
expect "A/B boot 4 reason, kind and idle timeout" serve_reason_ok
expect "A/B boot 4 file is set to 2" file_is 2
boot; expect "A/B boot 5 (reads 2) proceeds" [ "$RECOVERY" = 0 ]
expect "A/B boot 5 writes 3" file_is 3
expect "A/B boot 5 no second fallback" [ "${#SERVE_CALLS[@]}" = 1 ]
boot; expect "A/B boot 6 (reads 3) enters the fallback again" [ "$RECOVERY" = 1 ]
expect "A/B boot 6 serve-fallback called twice" [ "${#SERVE_CALLS[@]}" = 2 ]
expect "A/B boot 6 file is set to 2" file_is 2
expect "A/B: no boot FAT unmount inside the gate" [ "${#UMOUNT_CALLS[@]}" = 0 ]

# ---- 2. single-root layout (no unitotem.slot) counts the same way ----
new_case single "root=LABEL=ROOT ro quiet"
boot; boot; boot
expect "single root: boots 1-3 proceed and leave 3" file_is 3
boot; expect "single root: boot 4 enters the fallback" [ "$RECOVERY" = 1 ]

# ---- 3. inode and size: created once, then rewritten in place ----
new_case inode
boot
ino=$(inode_of)
boot; boot; boot
expect "inode unchanged over counter writes" [ "$(inode_of)" = "$ino" ]
boot
expect "inode unchanged through the fallback write" [ "$(inode_of)" = "$ino" ]
expect "size is 2 bytes after the fallback write" [ "$(stat -c %s "$BFILE")" = 2 ]

# ---- 4. garbage counts as 0 ----
new_case garbage_two
printf 'x\n' > "$BFILE"; ino=$(inode_of)
boot; expect "two-byte garbage counts as 0: proceeds" [ "$RECOVERY" = 0 ]
expect "two-byte garbage is replaced by 1" file_is 1
expect "two-byte garbage: inode unchanged" [ "$(inode_of)" = "$ino" ]

new_case garbage_long
printf '12345' > "$BFILE"
boot; expect "five-byte garbage counts as 0" file_is 1

new_case garbage_utf8
printf '\xc3\xa9\n' > "$BFILE"      # two characters in UTF-8, three bytes
boot; expect "multibyte garbage counts as 0" file_is 1

new_case digit_seven
printf '7\n' > "$BFILE"
boot; expect "digit 7 is a count: enters the fallback" [ "$RECOVERY" = 1 ]
expect "digit 7 is set to 2" file_is 2

# ---- 5. write failures never abort the boot ----
new_case missing_dir
OTA_BOOTFS_MNT="$TMP/missing_dir/no-such-dir"; BFILE="$OTA_BOOTFS_MNT/unitotem-ota.bootcount"
boot
expect "missing directory: boot proceeds" eval '[ "$GATE_RC" = 0 ] && [ "$RECOVERY" = 0 ]'
expect "missing directory: warning logged" [ "${#WARNS[@]}" -ge 1 ]

new_case unmounted
TEST_MOUNTED=0
boot
expect "unmounted boot FAT: boot proceeds with a warning" eval '[ "$RECOVERY" = 0 ] && [ "${#WARNS[@]}" -ge 1 ]'
expect "unmounted boot FAT: nothing created" [ ! -e "$BFILE" ]

new_case readonly_dir
mkdir -p "$OTA_BOOTFS_MNT/ro"; OTA_BOOTFS_MNT="$OTA_BOOTFS_MNT/ro"; BFILE="$OTA_BOOTFS_MNT/unitotem-ota.bootcount"
chmod 555 "$OTA_BOOTFS_MNT"
if [ "$(id -u)" = 0 ]; then
    echo "SKIP: read-only directory (running as root, permissions do not apply)"
else
    boot
    expect "read-only directory: boot proceeds with a warning" eval '[ "$RECOVERY" = 0 ] && [ "${#WARNS[@]}" -ge 1 ]'
fi
chmod 755 "$OTA_BOOTFS_MNT"

new_case readonly_file
printf '1\n' > "$BFILE"; chmod 444 "$BFILE"
if [ "$(id -u)" = 0 ]; then
    echo "SKIP: read-only file (running as root, permissions do not apply)"
else
    boot
    expect "read-only file: boot proceeds with a warning" eval '[ "$RECOVERY" = 0 ] && [ "${#WARNS[@]}" -ge 1 ]'
    expect "read-only file: content unchanged" file_is 1
fi
chmod 644 "$BFILE" 2>/dev/null

# ---- 6. legacy trial token starts the count fresh ----
new_case legacy_token "root=LABEL=ROOT ro quiet unitotem.ota.bootcount=1"
printf '3\n' > "$BFILE"
boot
expect "legacy token: count at 3 does not enter the fallback" eval '[ "$RECOVERY" = 0 ] && [ "${#SERVE_CALLS[@]}" = 0 ]'
expect "legacy token: count starts at 1" file_is 1

# ---- 7. A/B command line no longer skips the counter (full init-premount path) ----
new_case premount_ab "root=LABEL=ROOT ro quiet unitotem.slot=b"
cmd_init_premount; expect "init-premount A/B: returns 0" [ "$?" = 0 ]
expect "init-premount A/B: counter written" file_is 1
expect "init-premount A/B: boot FAT unmounted before mountroot" contains_umount "$OTA_BOOTFS_MNT"
expect "init-premount A/B: no fallback" [ "${#SERVE_CALLS[@]}" = 0 ]

new_case premount_ab_three "root=LABEL=ROOT ro quiet unitotem.slot=b"
printf '3\n' > "$BFILE"
cmd_init_premount
expect "init-premount A/B at 3: fallback entered" [ "${#SERVE_CALLS[@]}" = 1 ]
expect "init-premount A/B at 3: file set to 2" file_is 2
expect "init-premount A/B at 3: boot FAT left for the fallback" [ "${#UMOUNT_CALLS[@]}" = 0 ]

# ---- 8. fallback credentials with no DATA partition ----
auth_case() {   # auth_case NAME: fresh roots, boot dir and command line; DATA and FIRMWARE/EFI absent
    local dir="$TMP/$1"
    mkdir -p "$dir/boot" "$dir/root"
    OTA_AUTH_ROOT="$dir/root"; OTA_AUTH_BOOTDIR="$dir/boot"; OTA_AUTH_CMDLINE="$dir/cmdline"
    printf '%s\n' "root=LABEL=ROOT ro quiet" > "$OTA_AUTH_CMDLINE"
    unset OTA_AUTH_DATADIR
    LOGS=(); WARNS=()
}
auth_case auth_open
fallback_auth_setup; rc=$?
expect "no DATA, no key: setup returns 0" [ "$rc" = 0 ]
expect "no DATA, no key: open mode" [ "$FALLBACK_OPEN" = 1 ]
expect "no DATA, no key: root shadow has an empty password" grep -q '^root::19000:' "$OTA_AUTH_ROOT/etc/shadow"
expect "no DATA: DATA not found is logged" eval '[[ " ${LOGS[*]} " == *"DATA partition not found"* ]]'
expect "no DATA, no key: passwd has root" grep -qx 'root:x:0:0:root:/root:/bin/sh' "$OTA_AUTH_ROOT/etc/passwd"

auth_case auth_key
printf '%s\n' "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA fixture" \
    > "$OTA_AUTH_BOOTDIR/unitotem-ota.authorized_keys"
fallback_auth_setup; rc=$?
expect "no DATA, boot key: setup returns 0" [ "$rc" = 0 ]
expect "no DATA, boot key: root locked" [ "$FALLBACK_OPEN" = 0 ]
expect "no DATA, boot key: root shadow locked" grep -q '^root:\*:19000:' "$OTA_AUTH_ROOT/etc/shadow"
expect "no DATA, boot key: key installed" grep -q '^ssh-ed25519 ' "$OTA_AUTH_ROOT/root/.ssh/authorized_keys"

echo
echo "bootcount tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

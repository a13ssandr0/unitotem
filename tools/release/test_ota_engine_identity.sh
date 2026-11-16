#!/bin/bash
# Tests of the fallback-deploy identity path in deploy/script/ota-engine.sh: migrate-etc-overlay (archives the old /etc
# upper and prints UNITOTEM_ETC_HISTORY) and install-identity (validates and installs the merged account files into the
# new slot's /etc upper). Fixtures only, under a tmp directory: the DATA mount, the new root and the status files.
# Runs as root in the deploy test image (chown and file modes are checked for real).
#   bash tools/release/test_ota_engine_identity.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

if [ "${UNITOTEM_IDENTITY_TEST_INSIDE:-}" != 1 ]; then
    docker build -q -f "$REPO/tools/release/Dockerfile.deploy" -t unitotem-deploy-e2e "$REPO/tools/release" >/dev/null || exit 1
    exec docker run --rm -e UNITOTEM_IDENTITY_TEST_INSIDE=1 -v "$REPO:/repo:ro" unitotem-deploy-e2e \
        bash /repo/tools/release/test_ota_engine_identity.sh
fi

ENGINE="$REPO/deploy/script/ota-engine.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/unitotem-identity-engine.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# shellcheck disable=SC1090
. "$ENGINE"
set +e +u +o pipefail
trap - ERR   # the engine's ERR trap calls fail(), which exits; the tests check return codes themselves
OTA_STATUS_FILE="$TMP/status"; OTA_PCT_FILE="$TMP/pct"   # never /run on the test host

PASS=0; FAIL=0
check() {   # check NAME COND [DETAIL]
    if [ "$2" = 1 ]; then PASS=$((PASS + 1)); echo "PASS: $1"
    else FAIL=$((FAIL + 1)); echo "FAIL: $1 ${3:-}"; fi
}
same() { cmp -s "$1" "$2" && echo 1 || echo 0; }
mode_of() { stat -c '%a' "$1"; }
owner_of() { stat -c '%u:%g' "$1"; }

# ---- fixtures ----
ROOTFS="$TMP/root"
DATA="$TMP/data"
mkdir -p "$ROOTFS/etc/unitotem" "$DATA"
cp "$REPO/unitotem/files/ota-preserve.list" "$ROOTFS/etc/unitotem/ota-preserve.list"
# The live slot is read from the command line and the boot FAT's saved slot: fixtures, never the host's.
mkdir -p "$TMP/boot-empty"
printf 'console=tty1 ro quiet\n' > "$TMP/cmdline-plain"
export OTA_AUTH_CMDLINE="$TMP/cmdline-plain" OTA_AUTH_BOOTDIR="$TMP/boot-empty"

old_etc_upper() {   # the DATA upper of the old system: admin's accounts, a hostname, an unlisted file
    local u="$DATA/upper/etc.a"
    rm -rf -- "$DATA/upper" "$DATA/history"
    mkdir -p "$u" "$DATA/work/etc.a"
    printf 'old-host\n' > "$u/hostname"
    printf 'root:x:0:0:root:/root:/bin/bash\nadmin:x:1000:1000:Admin:/home/admin:/bin/bash\n' > "$u/passwd"
    printf 'root:$6$l$LOCALROOT:19500:0:99999:7:::\nadmin:$6$a$ADMINHASH:19600:0:99999:7:::\n' > "$u/shadow"
    printf 'root:x:0:\nsudo:x:27:admin\nadmin:x:1000:\n' > "$u/group"
    printf 'root:*::\nsudo:*::admin\nadmin:!::\n' > "$u/gshadow"
    chmod 640 "$u/shadow" "$u/gshadow"
}

# The merged set as deploy-identity.py writes it (valid, two local accounts).
merged_set() {   # DIR
    mkdir -p "$1"
    printf 'root:x:0:0:root:/root:/bin/bash\nnewsvc:x:991:991::/:/usr/sbin/nologin\nadmin:x:1000:1000:Admin:/home/admin:/bin/bash\n' > "$1/passwd"
    printf 'root:$6$l$LOCALROOT:19500:0:99999:7:::\nnewsvc:!*:19000::::::\nadmin:$6$a$ADMINHASH:19600:0:99999:7:::\n' > "$1/shadow"
    printf 'root:x:0:\nsudo:x:27:admin\nshadow:x:42:\nnewsvc:x:991:\nadmin:x:1000:\n' > "$1/group"
    printf 'root:*::\nsudo:*::admin\nshadow:*::\nnewsvc:!::\nadmin:!::\n' > "$1/gshadow"
}

# ---- migrate-etc-overlay ----
old_etc_upper
OUT=$( (main migrate-etc-overlay --root-mnt "$ROOTFS" --data-mnt "$DATA" --slot a) 2>/dev/null ); RC=$?
TS=$(printf '%s\n' "$OUT" | sed -n 's/^UNITOTEM_ETC_HISTORY=//p')
check "migrate-etc-overlay exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "migrate prints UNITOTEM_ETC_MIGRATED=1" "$(printf '%s\n' "$OUT" | grep -qx 'UNITOTEM_ETC_MIGRATED=1' && echo 1 || echo 0)"
check "migrate prints UNITOTEM_ETC_HISTORY with a history name" "$([[ "$TS" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && echo 1 || echo 0)" "ts=$TS"
check "the old passwd is archived in history" "$([ -f "$DATA/history/$TS/etc/passwd" ] && grep -q '^admin:' "$DATA/history/$TS/etc/passwd" && echo 1 || echo 0)"
check "the old shadow is archived in history" "$([ -f "$DATA/history/$TS/etc/shadow" ] && echo 1 || echo 0)"
check "hostname (ota-preserve.list) restored into the new upper" "$([ "$(cat "$DATA/upper/etc.a/hostname" 2>/dev/null)" = old-host ] && echo 1 || echo 0)"
check "passwd is not restored (identity merge owns it)" "$([ ! -e "$DATA/upper/etc.a/passwd" ] && echo 1 || echo 0)"
check "the new upper directory exists and is empty of account files" "$([ -d "$DATA/upper/etc.a" ] && [ ! -e "$DATA/upper/etc.a/shadow" ] && echo 1 || echo 0)"

old_etc_upper
rm -rf -- "$DATA/upper/etc.a"
OUT2=$( (main migrate-etc-overlay --root-mnt "$ROOTFS" --data-mnt "$DATA" --slot a) 2>/dev/null )
check "no etc upper: migrate prints no UNITOTEM_ETC_HISTORY" "$(printf '%s\n' "$OUT2" | grep -q '^UNITOTEM_ETC_HISTORY=' && echo 0 || echo 1)"
check "no etc upper: migrate still prints UNITOTEM_ETC_MIGRATED=1" "$(printf '%s\n' "$OUT2" | grep -qx 'UNITOTEM_ETC_MIGRATED=1' && echo 1 || echo 0)"

# ---- migrate-etc-overlay: the live system is slot b (it took an A/B update) ----
# both_slots_fixture NAME: a DATA tree with both slots. Slot b is the live system (admin account, hostname, root key);
# slot a is the target's stale leftover. The saved slot in the boot FAT is b unless the test changes it.
both_slots_fixture() {
    local dir="$TMP/$1"
    mkdir -p "$dir/upper/etc.a" "$dir/upper/etc.b" "$dir/upper/root.a/.ssh" "$dir/upper/root.b/.ssh" \
        "$dir/work/etc.a" "$dir/work/etc.b" "$dir/work/root.a" "$dir/work/root.b" "$dir/boot/unitotem-grub/grub"
    printf 'a-stale-host\n' > "$dir/upper/etc.a/hostname"
    printf 'root:x:0:\n' > "$dir/upper/etc.a/group"
    printf 'b-host\n' > "$dir/upper/etc.b/hostname"
    printf 'root:x:0:0:root:/root:/bin/bash\nadmin:x:1000:1000:Admin:/home/admin:/bin/bash\n' > "$dir/upper/etc.b/passwd"
    printf 'root:$6$l$LOCALROOT:19500:0:99999:7:::\nadmin:$6$a$ADMINHASH:19600:0:99999:7:::\n' > "$dir/upper/etc.b/shadow"
    printf 'root:x:0:\nsudo:x:27:admin\nadmin:x:1000:\n' > "$dir/upper/etc.b/group"
    printf 'root:*::\nsudo:*::admin\nadmin:!::\n' > "$dir/upper/etc.b/gshadow"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBLIVEKEY admin@live\n' > "$dir/upper/root.b/.ssh/authorized_keys"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSTALEKEY old@a\n' > "$dir/upper/root.a/.ssh/authorized_keys"
    printf 'saved_entry=slot-b\n' > "$dir/boot/unitotem-grub/grub/grubenv"
    echo "$dir"
}

# run_migrate DIR CMDLINE: migrate-etc-overlay --slot a against DIR, with CMDLINE as the kernel command line.
# Sets OUT (stdout), RC and TSX (the UNITOTEM_ETC_HISTORY value).
run_migrate() {
    printf '%s\n' "$2" > "$1/cmdline"
    export OTA_AUTH_CMDLINE="$1/cmdline" OTA_AUTH_BOOTDIR="$1/boot"
    OUT=$( (main migrate-etc-overlay --root-mnt "$ROOTFS" --data-mnt "$1" --slot a) 2>/dev/null ); RC=$?
    TSX=$(printf '%s\n' "$OUT" | sed -n 's/^UNITOTEM_ETC_HISTORY=//p')
}

# check_live_b NAME DIR: the migration of a live slot b, to slot a.
check_live_b() {
    local n="$1" D="$2" H
    H="$D/history/$TSX"
    check "$n: exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
    check "$n: UNITOTEM_ETC_MIGRATED=1 printed" "$(printf '%s\n' "$OUT" | grep -qx 'UNITOTEM_ETC_MIGRATED=1' && echo 1 || echo 0)"
    check "$n: UNITOTEM_ETC_HISTORY printed with a history name" "$([[ "$TSX" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && echo 1 || echo 0)" "ts=$TSX"
    check "$n: live passwd archived in history" "$(grep -q '^admin:' "$H/etc/passwd" 2>/dev/null && echo 1 || echo 0)"
    check "$n: live hostname archived in history" "$([ "$(cat "$H/etc/hostname" 2>/dev/null)" = b-host ] && echo 1 || echo 0)"
    check "$n: live hostname restored into etc.a" "$([ "$(cat "$D/upper/etc.a/hostname" 2>/dev/null)" = b-host ] && echo 1 || echo 0)"
    check "$n: passwd not restored into etc.a (identity merge owns it)" "$([ ! -e "$D/upper/etc.a/passwd" ] && echo 1 || echo 0)"
    check "$n: live root key carried to root.a" "$(grep -q 'admin@live' "$D/upper/root.a/.ssh/authorized_keys" 2>/dev/null && echo 1 || echo 0)"
    check "$n: target's stale root key archived, not dropped" "$(grep -q 'old@a' "$H/root.a/.ssh/authorized_keys" 2>/dev/null && echo 1 || echo 0)"
    check "$n: target's stale etc archived under etc.a" "$([ "$(cat "$H/etc.a/hostname" 2>/dev/null)" = a-stale-host ] && echo 1 || echo 0)"
    check "$n: live upper etc.b gone" "$([ ! -e "$D/upper/etc.b" ] && echo 1 || echo 0)"
    check "$n: live upper root.b gone" "$([ ! -e "$D/upper/root.b" ] && echo 1 || echo 0)"
    check "$n: live work etc.b and root.b gone" "$([ ! -e "$D/work/etc.b" ] && [ ! -e "$D/work/root.b" ] && echo 1 || echo 0)"
    check "$n: target upper etc.a recreated" "$([ -d "$D/upper/etc.a" ] && echo 1 || echo 0)"
}

# b1: saved slot b, no unitotem.slot on the command line.
D=$(both_slots_fixture live-b-saved)
run_migrate "$D" "console=tty1 ro quiet"
check_live_b "live b (saved slot-b)" "$D"

# b2: the command line selects b; the saved slot says a, the command line wins.
D=$(both_slots_fixture live-b-cmdline)
printf 'saved_entry=slot-a\n' > "$D/boot/unitotem-grub/grub/grubenv"
run_migrate "$D" "console=tty1 unitotem.slot=b ro quiet"
check_live_b "live b (unitotem.slot=b)" "$D"

# check_live_a NAME DIR: the migration of a live slot a (the target): the other slot's leftovers are archived under
# history/ with their slot name, nothing is dropped, the target's own /etc is archived as before.
check_live_a() {
    local n="$1" D="$2" H
    H="$D/history/$TSX"
    check "$n: exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
    check "$n: UNITOTEM_ETC_MIGRATED=1 printed" "$(printf '%s\n' "$OUT" | grep -qx 'UNITOTEM_ETC_MIGRATED=1' && echo 1 || echo 0)"
    check "$n: live hostname of a archived" "$([ "$(cat "$H/etc/hostname" 2>/dev/null)" = a-stale-host ] && echo 1 || echo 0)"
    check "$n: other slot's etc archived as etc.b" "$(grep -q '^admin:' "$H/etc.b/passwd" 2>/dev/null && [ "$(cat "$H/etc.b/hostname" 2>/dev/null)" = b-host ] && echo 1 || echo 0)"
    check "$n: other slot's etc work dir archived as etc.b.work" "$([ -d "$H/etc.b.work" ] && echo 1 || echo 0)"
    check "$n: other slot's root key archived as root.b" "$(grep -q 'admin@live' "$H/root.b/.ssh/authorized_keys" 2>/dev/null && echo 1 || echo 0)"
    check "$n: other slot's root work dir archived as root.b.work" "$([ -d "$H/root.b.work" ] && echo 1 || echo 0)"
    check "$n: other slot's upper and work gone from DATA" "$([ ! -e "$D/upper/etc.b" ] && [ ! -e "$D/upper/root.b" ] && [ ! -e "$D/work/etc.b" ] && [ ! -e "$D/work/root.b" ] && echo 1 || echo 0)"
    check "$n: root.a kept as it was" "$(grep -q 'old@a' "$D/upper/root.a/.ssh/authorized_keys" 2>/dev/null && echo 1 || echo 0)"
    check "$n: no root.a archive" "$([ ! -e "$H/root.a" ] && echo 1 || echo 0)"
    check "$n: target upper etc.a recreated" "$([ -d "$D/upper/etc.a" ] && echo 1 || echo 0)"
}

# b3: the live slot is a (command line): the other slot's leftovers are archived, nothing is dropped.
D=$(both_slots_fixture live-a-cmdline)
run_migrate "$D" "console=tty1 unitotem.slot=a ro quiet"
check_live_a "live a (unitotem.slot=a)" "$D"

# set_mtimes DIR SLOT STAMP: sets the mtime of the account files of upper/etc.SLOT to STAMP (touch -d).
set_mtimes() {
    local f
    for f in passwd shadow group gshadow; do
        [ -e "$1/upper/etc.$2/$f" ] && touch -d "$3" "$1/upper/etc.$2/$f"
    done
    return 0
}

# No unitotem.slot and no saved slot (the deploy-time state: saved_entry=ota-recovery). Both slots have accounts:
# the slot with the newest account file is the live one.
nohint_fixture() {   # NAME: both slots, no hint in the boot FAT
    local D; D=$(both_slots_fixture "$1")
    printf 'saved_entry=ota-recovery\n' > "$D/boot/unitotem-grub/grub/grubenv"
    echo "$D"
}

# c1: no hint, the live b accounts are newer: live b.
D=$(nohint_fixture nohint-b-newer)
set_mtimes "$D" a "2026-11-01 10:00:00 UTC"
set_mtimes "$D" b "2026-11-10 10:00:00 UTC"
run_migrate "$D" "console=tty1 ro quiet"
check_live_b "no hint, live b newer" "$D"

# c2: no hint, the live a accounts are newer: live a.
D=$(nohint_fixture nohint-a-newer)
set_mtimes "$D" a "2026-11-12 10:00:00 UTC"
set_mtimes "$D" b "2026-11-10 10:00:00 UTC"
run_migrate "$D" "console=tty1 ro quiet"
check_live_a "no hint, live a newer" "$D"

# c3: no hint, the newest account files of both slots have the same mtime: a (the tie order).
D=$(nohint_fixture nohint-tie)
set_mtimes "$D" a "2026-11-11 10:00:00 UTC"
set_mtimes "$D" b "2026-11-11 10:00:00 UTC"
run_migrate "$D" "console=tty1 ro quiet"
check_live_a "no hint, tie" "$D"

# c4: no hint, only the newer file of a counts: a's shadow is newer than every file of b.
D=$(nohint_fixture nohint-newest-file)
set_mtimes "$D" a "2026-11-01 10:00:00 UTC"
set_mtimes "$D" b "2026-11-05 10:00:00 UTC"
touch -d "2026-11-20 10:00:00 UTC" "$D/upper/etc.a/group"
run_migrate "$D" "console=tty1 ro quiet"
check_live_a "no hint, newest file of a is newest overall" "$D"

# b4: saved slot b, but slot b has no /etc upper: the live slot is a (the target), as before.
D="$TMP/only-a"
mkdir -p "$D/upper/etc.a" "$D/boot/unitotem-grub/grub"
printf 'a-host\n' > "$D/upper/etc.a/hostname"
printf 'saved_entry=slot-b\n' > "$D/boot/unitotem-grub/grub/grubenv"
run_migrate "$D" "console=tty1 ro quiet"
check "saved slot-b without etc.b: exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "saved slot-b without etc.b: target's own etc archived" "$([ "$(cat "$D/history/$TSX/etc/hostname" 2>/dev/null)" = a-host ] && echo 1 || echo 0)"

# b5: an invalid slot is refused before anything changes (standalone run: fail() exits).
D=$(both_slots_fixture bad-slot)
before=$(cd "$D" && find . | LC_ALL=C sort | cksum)
bash "$ENGINE" migrate-etc-overlay --root-mnt "$ROOTFS" --data-mnt "$D" --slot c >/dev/null 2>&1; RC=$?
after=$(cd "$D" && find . | LC_ALL=C sort | cksum)
check "invalid --slot c refused (exit 1)" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
check "invalid --slot c changes nothing" "$([ "$before" = "$after" ] && echo 1 || echo 0)"

# ---- install-identity ----
NEWUP="$DATA/upper/etc.a"
SRC="$TMP/stage"
rm -rf -- "$DATA/upper" && mkdir -p "$DATA/upper"
merged_set "$SRC"
mkdir -p "$NEWUP"
printf 'old passwd\n' > "$NEWUP/passwd"

run_install() {   # extra args: run the engine as a standalone command, the way the deploy calls it
    bash "$ENGINE" install-identity --data-mnt "$DATA" --slot a --src "$SRC" "$@" 2>/dev/null
}

run_install --shadow-gid 42 >/dev/null; RC=$?
check "install-identity exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
for f in passwd group shadow gshadow; do
    check "installed $f equals the merged file" "$(same "$SRC/$f" "$NEWUP/$f")"
done
check "passwd mode 644" "$([ "$(mode_of "$NEWUP/passwd")" = 644 ] && echo 1 || echo 0)" "$(mode_of "$NEWUP/passwd")"
check "group mode 644" "$([ "$(mode_of "$NEWUP/group")" = 644 ] && echo 1 || echo 0)"
check "shadow mode 640" "$([ "$(mode_of "$NEWUP/shadow")" = 640 ] && echo 1 || echo 0)" "$(mode_of "$NEWUP/shadow")"
check "gshadow mode 640" "$([ "$(mode_of "$NEWUP/gshadow")" = 640 ] && echo 1 || echo 0)" "$(mode_of "$NEWUP/gshadow")"
check "shadow owned by root:42 (--shadow-gid)" "$([ "$(owner_of "$NEWUP/shadow")" = 0:42 ] && echo 1 || echo 0)" "$(owner_of "$NEWUP/shadow")"
check "passwd owned by root:root" "$([ "$(owner_of "$NEWUP/passwd")" = 0:0 ] && echo 1 || echo 0)" "$(owner_of "$NEWUP/passwd")"
check "previous passwd kept as passwd.pre-update" "$([ "$(cat "$NEWUP/passwd.pre-update" 2>/dev/null)" = 'old passwd' ] && echo 1 || echo 0)"
check "no temporary files left behind" "$(ls -A "$NEWUP" | grep -q identity-new && echo 0 || echo 1)"

# Rerun (idempotent): same files, the .pre-update still holds the original previous file.
run_install --shadow-gid 42 >/dev/null; RC=$?
check "rerun exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "rerun keeps the set identical" "$(same "$SRC/shadow" "$NEWUP/shadow")"
check "rerun does not overwrite passwd.pre-update with the new content" "$([ "$(cat "$NEWUP/passwd.pre-update")" = 'old passwd' ] && echo 1 || echo 0)"

# An interrupted earlier install left a temporary file: the rerun replaces it.
printf 'stale\n' > "$NEWUP/.passwd.identity-new"
run_install --shadow-gid 42 >/dev/null
check "rerun over a stale temporary file completes" "$(same "$SRC/passwd" "$NEWUP/passwd")"
check "stale temporary file is gone" "$([ ! -e "$NEWUP/.passwd.identity-new" ] && echo 1 || echo 0)"

# Refusals: nothing in the new upper may change.
snapshot() { (cd "$NEWUP" && for f in *; do [ -f "$f" ] && cksum < "$f"; done; ls -A) 2>/dev/null; }
refuse() {   # NAME: run install-identity with the current SRC/ARGS, expect exit 1 and no change
    local name="$1"; local before; before=$(snapshot)
    run_install --shadow-gid 42 >/dev/null; local rc=$?
    local after; after=$(snapshot)
    check "$name refused (exit 1)" "$([ "$rc" = 1 ] && echo 1 || echo 0)" "rc=$rc"
    check "$name changes nothing" "$([ "$before" = "$after" ] && echo 1 || echo 0)"
    merged_set "$SRC"
}

rm -f "$SRC/shadow"; refuse "missing shadow"
printf '' > "$SRC/gshadow"; refuse "empty gshadow"
printf 'nobody:x:65534:65534::/:/usr/sbin/nologin\n' > "$SRC/passwd"; refuse "passwd without root"
printf 'elsewhere\n' > "$TMP/elsewhere"
rm -f -- "$SRC/group"; ln -s "$TMP/elsewhere" "$SRC/group"; refuse "symlink in place of group"
rm -f -- "$SRC/group"
merged_set "$SRC"
# A file the validation has not seen yet: refused before any rename.
OUT3=$(bash "$ENGINE" install-identity --data-mnt "$DATA" --slot c --src "$SRC" 2>/dev/null); RC=$?
check "slot other than a or b refused" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
OUT4=$(bash "$ENGINE" install-identity --data-mnt "$DATA" --slot a --src "$SRC" --shadow-gid 4x 2>/dev/null); RC=$?
check "non-numeric --shadow-gid refused" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
OUT5=$(bash "$ENGINE" install-identity --data-mnt "$DATA" --slot a 2>/dev/null); RC=$?
check "missing --src refused" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
OUT6=$(bash "$ENGINE" install-identity --data-mnt "$TMP/nodata" --slot a --src "$SRC" 2>/dev/null); RC=$?
check "missing DATA mount refused" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"

# Without --shadow-gid the shadow files stay root:root (rerun with no gid).
bash "$ENGINE" install-identity --data-mnt "$DATA" --slot a --src "$SRC" >/dev/null 2>&1; RC=$?
check "install without --shadow-gid exits 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "shadow owned by root:root without --shadow-gid" "$([ "$(owner_of "$NEWUP/shadow")" = 0:0 ] && echo 1 || echo 0)" "$(owner_of "$NEWUP/shadow")"

echo
echo "identity engine tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

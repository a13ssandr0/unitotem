#!/bin/bash
# Tests of deploy_carry_identity (deploy/script/identity-carry.sh) against a local stand-in for the target: ota_ssh and
# ota_ssh_send run the remote command in bash after rewriting /mnt/newroot to a tmp tree and unitotem-ota-engine to the
# engine script. Covers: the carry, nothing to carry, a refused merge (warned, returns 0), a bad history name, a failed
# install (returns 1, stage removed), idempotent rerun, and the temporary directory being removed. No real target.
#   bash tools/release/test_identity_carry.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

if [ "${UNITOTEM_IDENTITY_TEST_INSIDE:-}" != 1 ]; then
    # The deploy test image plus python3 (deploy-identity.py runs on the deploy host, which has it).
    docker build -q -f "$REPO/tools/release/Dockerfile.deploy" -t unitotem-deploy-e2e "$REPO/tools/release" >/dev/null || exit 1
    printf 'FROM unitotem-deploy-e2e\nRUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*\n' \
        | docker build -q -t unitotem-identity-carry - >/dev/null || exit 1
    exec docker run --rm -e UNITOTEM_IDENTITY_TEST_INSIDE=1 -v "$REPO:/repo:ro" unitotem-identity-carry \
        bash /repo/tools/release/test_identity_carry.sh
fi

ENGINE="$REPO/deploy/script/ota-engine.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/unitotem-identity-carry.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
NR="$TMP/newroot"          # stands for /mnt/newroot on the target
TMPFS="$TMP/tmpfs"         # stands for IMG_TMPFS
mkdir -p "$TMPFS"
IMG_TMPFS="$TMPFS"
export OTA_STATUS_FILE="$TMP/status" OTA_PCT_FILE="$TMP/pct"

# ---- stand-ins for lib.sh (the real ones need a target) ----
WARNS=(); FAIL_MATCH=""
warn() { WARNS+=("$*"); }
remote_exec() {   # remote command text -> run locally, paths rewritten
    local c="$1"
    c="${c//\/mnt\/newroot/$NR}"
    c="${c//unitotem-ota-engine/bash $ENGINE}"
    if [ -n "$FAIL_MATCH" ] && [[ "$c" == *"$FAIL_MATCH"* ]]; then return 1; fi
    bash -c "$c"
}
ota_ssh()      { local host="$1"; shift; remote_exec "$*"; }
ota_ssh_send() { local host="$1"; shift; remote_exec "$*"; }   # stdin passes through to the remote command

# shellcheck disable=SC1091
. "$REPO/deploy/script/identity-carry.sh"

PASS=0; FAIL=0
check() {   # check NAME COND [DETAIL]
    if [ "$2" = 1 ]; then PASS=$((PASS + 1)); echo "PASS: $1"
    else FAIL=$((FAIL + 1)); echo "FAIL: $1 ${3:-}"; fi
}
b() { if "$@"; then echo 1; else echo 0; fi; }

TS=20261114T120000Z
HIST="$NR/mnt/data/history/$TS/etc"
UPPER="$NR/mnt/data/upper/etc.a"

old_set() {   # the archived old /etc upper: admin 1000, a local group
    rm -rf -- "$NR"
    mkdir -p "$HIST" "$UPPER" "$NR/etc"
    printf 'root:x:0:0:root:/root:/bin/bash\nadmin:x:1000:1000:Admin:/home/admin:/bin/bash\n' > "$HIST/passwd"
    printf 'root:$6$l$LOCALROOT:19500:0:99999:7:::\nadmin:$6$a$ADMINHASH:19600:0:99999:7:::\n' > "$HIST/shadow"
    printf 'root:x:0:\nsudo:x:27:admin\nadmin:x:1000:\n' > "$HIST/group"
    printf 'root:*::\nsudo:*::admin\nadmin:!::\n' > "$HIST/gshadow"
    # the new image's /etc
    printf 'root:x:0:0:root:/root:/bin/bash\nnewsvc:x:991:991::/:/usr/sbin/nologin\n' > "$NR/etc/passwd"
    printf 'root:!:19000:0:99999:7:::\nnewsvc:!*:19000::::::\n' > "$NR/etc/shadow"
    printf 'root:x:0:\nsudo:x:27:\nshadow:x:42:\nnewsvc:x:991:\n' > "$NR/etc/group"
    printf 'root:*::\nsudo:*::\nshadow:*::\nnewsvc:!::\n' > "$NR/etc/gshadow"
    chmod 640 "$NR/etc/shadow" "$NR/etc/gshadow" 2>/dev/null || true
}

tmp_left() { ls -A "$TMPFS" | wc -l; }

# 1. carry
old_set; WARNS=(); FAIL_MATCH=""
deploy_carry_identity host "$TS"; RC=$?
check "carry returns 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "admin is in the new upper passwd" "$(b grep -q '^admin:x:1000:' "$UPPER/passwd")"
check "admin's hash is in the new upper shadow" "$(b grep -q 'ADMINHASH' "$UPPER/shadow")"
check "the image's system user newsvc is kept" "$(b grep -q '^newsvc:' "$UPPER/passwd")"
check "shadow installed mode 640 with group 42" "$([ "$(stat -c '%a %u:%g' "$UPPER/shadow")" = '640 0:42' ] && echo 1 || echo 0)" "$(stat -c '%a %u:%g' "$UPPER/shadow")"
check "stage directory removed from the target" "$(b test ! -e "$UPPER/.identity-stage")"
check "no temporary directory left on IMG_TMPFS" "$([ "$(tmp_left)" = 0 ] && echo 1 || echo 0)" "left=$(tmp_left)"

# 2. idempotent rerun
deploy_carry_identity host "$TS"; RC=$?
check "rerun returns 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "rerun leaves admin in place" "$(b grep -q 'ADMINHASH' "$UPPER/shadow")"
check "rerun leaves no temporary directory" "$([ "$(tmp_left)" = 0 ] && echo 1 || echo 0)" "left=$(tmp_left)"

# 3. nothing archived: no history name
old_set; rm -f -- "$UPPER/passwd"
deploy_carry_identity host ""; RC=$?
check "empty history name: returns 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "empty history name: nothing installed" "$(b test ! -e "$UPPER/passwd")"

# 4. history exists but holds no account files
old_set; rm -f -- "$HIST/passwd" "$HIST/shadow" "$HIST/group" "$HIST/gshadow"
deploy_carry_identity host "$TS"; RC=$?
check "no account files archived: returns 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "no account files archived: nothing installed" "$(b test ! -e "$UPPER/passwd")"

# 5. refused merge (corrupt old shadow): warned, returns 0, nothing installed
old_set; printf 'root:$6$x:1:0:99999:7:::\n\x00\x01garbage\n' > "$HIST/shadow"; WARNS=()
deploy_carry_identity host "$TS"; RC=$?
check "refused merge: returns 0" "$([ "$RC" = 0 ] && echo 1 || echo 0)" "rc=$RC"
check "refused merge: warned" "$([ "${#WARNS[@]}" -ge 1 ] && echo 1 || echo 0)"
check "refused merge: nothing installed" "$(b test ! -e "$UPPER/passwd")"
check "refused merge: no temporary directory left" "$([ "$(tmp_left)" = 0 ] && echo 1 || echo 0)" "left=$(tmp_left)"

# 6. bad history name: refused before any ssh
old_set; WARNS=()
deploy_carry_identity host "../etc"; RC=$?
check "bad history name: returns 1" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
check "bad history name: nothing installed" "$(b test ! -e "$UPPER/passwd")"

# 7. install step fails on the target: returns 1, stage removed, no temporary directory left
old_set; FAIL_MATCH="install-identity"
deploy_carry_identity host "$TS"; RC=$?
FAIL_MATCH=""
check "failed install: returns 1" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
check "failed install: stage removed" "$(b test ! -e "$UPPER/.identity-stage")"
check "failed install: no temporary directory left" "$([ "$(tmp_left)" = 0 ] && echo 1 || echo 0)" "left=$(tmp_left)"

# 8. transfer fails while staging: returns 1, stage removed
old_set; FAIL_MATCH="cat > "
deploy_carry_identity host "$TS"; RC=$?
FAIL_MATCH=""
check "failed transfer: returns 1" "$([ "$RC" = 1 ] && echo 1 || echo 0)" "rc=$RC"
check "failed transfer: stage removed" "$(b test ! -e "$UPPER/.identity-stage")"
check "failed transfer: nothing installed" "$(b test ! -e "$UPPER/passwd")"

echo
echo "identity carry tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

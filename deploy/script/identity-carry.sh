#!/bin/bash
# Carries the local accounts over a fallback deploy that keeps DATA. The old /etc upper, archived by
# migrate-etc-overlay in DATA history, is merged with the new image's files on the deploy host (deploy-identity.py,
# unitotem_identity.py) and the result is installed into the new slot's /etc upper on the target
# (ota-engine.sh install-identity). Sourced by remote-deploy.sh after lib.sh (ota_ssh, ota_ssh_send, warn).
#   deploy_carry_identity HOST HIST_TS
# HIST_TS: the history name printed as UNITOTEM_ETC_HISTORY by migrate-etc-overlay (empty: nothing was archived).
# Returns 0: nothing to carry, merged and installed, or merge refused (warned: the new system uses the image's accounts).
# Returns 1: transfer or install failed (warned by the caller; the new system uses the image's accounts).
# Idempotent: a rerun repeats the whole carry; install-identity completes an interrupted install.

IDENTITY_CARRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_NEWROOT=/mnt/newroot
IDENTITY_FILES="passwd group shadow gshadow"

# Removes the known files of a carry work directory and the directories themselves (literal names only).
_identity_clean() {   # DIR
    local d="$1"
    [ -n "$d" ] && [ -d "$d" ] || return 0
    rm -f -- "$d/old/passwd" "$d/old/group" "$d/old/shadow" "$d/old/gshadow" \
             "$d/new/passwd" "$d/new/group" "$d/new/shadow" "$d/new/gshadow" \
             "$d/out/passwd" "$d/out/group" "$d/out/shadow" "$d/out/gshadow"
    rmdir -- "$d/old" "$d/new" "$d/out" 2>/dev/null || true
    rmdir -- "$d" 2>/dev/null || true
}

# Runs the carry inside DIR (already created, 0700). Every failure returns, so the caller always cleans up.
_identity_run() {   # HOST HIST_TS DIR
    local host="$1" ts="$2" d="$3"
    local hist="$IDENTITY_NEWROOT/mnt/data/history/$ts/etc"
    local stage="$IDENTITY_NEWROOT/mnt/data/upper/etc.a/.identity-stage"
    local f present="" res rc gid=""

    # Which of the four files the old /etc upper holds (none: no local accounts were ever made).
    present=$(ota_ssh "$host" "for f in $IDENTITY_FILES; do if [ -f '$hist'/\$f ]; then echo \$f; fi; done") || return 1
    [ -n "$present" ] || return 0

    mkdir -p -- "$d/old" "$d/new" "$d/out" || return 1
    for f in $present; do
        ota_ssh "$host" "cat '$hist/$f'" > "$d/old/$f" || return 1
    done
    for f in $IDENTITY_FILES; do
        ota_ssh "$host" "cat '$IDENTITY_NEWROOT/etc/$f'" > "$d/new/$f" || return 1
    done

    # Merge on this host. Exit 1: refused (nothing written); other codes: the helper itself failed.
    res=$(python3 -I "$IDENTITY_CARRY_DIR/deploy-identity.py" --old-dir "$d/old" --new-dir "$d/new" --out-dir "$d/out") && rc=0 || rc=$?
    if [ "$rc" -eq 1 ]; then
        warn "local accounts NOT carried (merge refused): the new system starts with the image's own accounts, use first access"
        return 0
    fi
    [ "$rc" -eq 0 ] || return 1
    gid=$(printf '%s\n' "$res" | sed -n 's/.*"shadow_gid": \([0-9][0-9]*\).*/\1/p')

    # Stage the merged files: umask 077, the shadow hashes must never be readable on the target.
    ota_ssh "$host" "umask 077; rm -rf -- '$stage'; mkdir -p -- '$stage'" || return 1
    for f in $IDENTITY_FILES; do
        ota_ssh_send "$host" "umask 077; cat > '$stage/$f'" < "$d/out/$f" || { ota_ssh "$host" "rm -rf -- '$stage'" || true; return 1; }
    done
    ota_ssh "$host" "unitotem-ota-engine install-identity --data-mnt $IDENTITY_NEWROOT/mnt/data --slot a --src '$stage'${gid:+ --shadow-gid $gid}" \
        && rc=0 || rc=1
    ota_ssh "$host" "rm -rf -- '$stage'" || true
    return "$rc"
}

deploy_carry_identity() {   # HOST HIST_TS
    local host="$1" ts="${2:-}" d
    [ -n "$ts" ] || return 0
    [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { warn "identity carry: bad history name '$ts'"; return 1; }
    d=$(mktemp -d "${IMG_TMPFS:-/tmp}/unitotem-identity.XXXXXX") || return 1
    chmod 700 "$d"
    _identity_run "$host" "$ts" "$d"
    local rc=$?
    _identity_clean "$d"
    return "$rc"
}

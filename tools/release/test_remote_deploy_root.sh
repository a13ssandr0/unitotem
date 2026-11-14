#!/bin/bash
# Test of the privilege handling of deploy/script/remote-deploy.sh and make-preboot-image.sh: --help and probe/changes/disarm need no root;
# deploy and recover run the script again through sudo with the variables it reads (sudo-rs ignores -E). A stub `sudo` records its arguments;
# nothing is executed as root.
#   tools/release/test_remote_deploy_root.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/rdroot.XXXXXX"); trap 'rm -f -- "$T/bin/sudo" "$T/sudo.args"; rmdir -- "$T/bin" "$T" 2>/dev/null' EXIT
mkdir -p "$T/bin"; printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/sudo.args"\nexit 0\n' "$T" > "$T/bin/sudo"; chmod +x "$T/bin/sudo"
ok=0; fail=0
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $n"; else fail=$((fail + 1)); echo "FAIL: $n"; fi; }
SUDO_BIN="$T/bin"
for s in remote-deploy.sh make-preboot-image.sh; do
    check "$s --help prints the usage, no sudo" bash -c "rm -f $T/sudo.args; PATH=$SUDO_BIN:\$PATH bash $DIR/deploy/script/$s --help | grep -q -i usage; [ ! -e $T/sudo.args ]"
done
check "remote-deploy.sh with no arguments prints the usage, no sudo" bash -c "rm -f $T/sudo.args; PATH=$SUDO_BIN:\$PATH bash $DIR/deploy/script/remote-deploy.sh 2>&1 | grep -q Usage; [ ! -e $T/sudo.args ]"
if [ "$(id -u)" != 0 ]; then
    for sub in deploy recover; do
        rm -f "$T/sudo.args"
        OTA_FALLBACK_KEY=/k/key UNITOTEM_BACKUP_DIR=/b OTHER_SECRET=nope PATH="$SUDO_BIN:$PATH" bash "$DIR/deploy/script/remote-deploy.sh" "$sub" root@host --yes >/dev/null 2>&1
        check "$sub goes through sudo env with OTA_FALLBACK_KEY" grep -qx 'OTA_FALLBACK_KEY=/k/key' "$T/sudo.args"
        check "$sub passes UNITOTEM_BACKUP_DIR and HOME" bash -c "grep -qx 'UNITOTEM_BACKUP_DIR=/b' $T/sudo.args && grep -qx 'HOME=$HOME' $T/sudo.args"
        check "$sub does not pass unrelated variables" bash -c "! grep -q OTHER_SECRET $T/sudo.args"
        check "$sub runs the same script with its arguments, no -E" bash -c "grep -qx '$DIR/deploy/script/remote-deploy.sh' $T/sudo.args && grep -qx $sub $T/sudo.args && grep -qx root@host $T/sudo.args && ! grep -qx -- '-E' $T/sudo.args"
    done
    for sub in probe changes disarm; do
        rm -f "$T/sudo.args"
        PATH="$SUDO_BIN:$PATH" timeout 20 bash "$DIR/deploy/script/remote-deploy.sh" "$sub" nobody@127.0.0.1 >/dev/null 2>&1
        check "$sub does not ask for root" [ ! -e "$T/sudo.args" ]
    done
fi
echo "$ok passed, $fail failed"; [ "$fail" = 0 ]

#!/bin/bash
# unitotem/files/ota-hook reads its names from ota-initrd.list. The hook runs against a fixture list with stubbed
# copy_exec/copy_file/manual_add_modules (the call log must match exactly), a PATH of stub tools and a DESTDIR inside
# the test folder. Then: no name of the real list is left in the hook, the install sites ship the list, lists.py
# parses the real list and rejects malformed ones. Nothing outside the test folder is written or read as a system file.
#   tools/release/test_ota_initrd_list.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD
fail=0
t=$(mktemp -d /tmp/test-ota-initrd-list.XXXXXX) || exit 1
cleanup() { python3 -I -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$t"; }
trap cleanup EXIT
mkdir -p "$t/bin" "$t/dest" "$t/lib" "$t/ti1" "$t/ti2/l" "$t/ti2/v" "$t/grub/i386"
CALLS="$t/calls.log"
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# Stub tools: every name the fixture list resolves through command -v, plus nc and reboot.
for n in fxbash fxone fxtwo fxdd fxefi fxgrub nc reboot; do
    printf '#!/bin/sh\nexit 0\n' > "$t/bin/$n"; chmod 755 "$t/bin/$n"
done
printf '#!/bin/sh\necho x86_64\n' > "$t/bin/uname"; chmod 755 "$t/bin/uname"
printf '#!/bin/sh\necho "\tlibfx.so.1 => %s/lib/libfx.so.1 (0x0)"\n' "$t" > "$t/bin/ldd"; chmod 755 "$t/bin/ldd"
printf '#!/bin/sh\n[ "$3" = fxb ] && exit 0\nexit 1\n' > "$t/bin/modinfo"; chmod 755 "$t/bin/modinfo"
: > "$t/lib/libfx.so.1"
: > "$t/ti2/l/linux"; : > "$t/ti2/v/vt220"

# Fixture list: every directive, one missing name (warning), one real binary, terminfo found in the second dir only.
cat > "$t/ota-initrd.list" << LIST
# fixture
bin fxbash
file /usr/lib/unitotem/ota-engine.sh
file /etc/group
bin fxone fxmissing fxtwo
real fxdd fxnotthere
terminfo l/linux v/vt220 v/vt100
module vfat nls_fx
module-opt fxa fxb
x86-bin fxefi fxgrub
x86-module efivarfs
x86-dir $t/grub/i386 $t/grub/missing
LIST

# Stubs of the hook-functions API: the call log is the observable behaviour.
cat > "$t/hook-functions" << STUB
CALLS="$CALLS"
copy_exec() { echo "copy_exec \$1" >> "\$CALLS"; }
copy_file() { echo "copy_file \$*" >> "\$CALLS"; }
manual_add_modules() { echo "manual_add_modules \$*" >> "\$CALLS"; }
STUB

# The hook with its absolute paths pointed into the fixture: the list, hook-functions and the terminfo search dirs.
sed -e "s|^LIST=/usr/share/unitotem-ota/ota-initrd.list|LIST=$t/ota-initrd.list|" \
    -e "s|^\. /usr/share/initramfs-tools/hook-functions|. $t/hook-functions|" \
    -e "s|for dir in /usr/share/terminfo /lib/terminfo /usr/lib/terminfo; do|for dir in $t/ti1 $t/ti2; do|" \
    "$REPO/unitotem/files/ota-hook" > "$t/ota-hook"

run_hook() {
    : > "$CALLS"
    env -i PATH="$t/bin:/usr/bin:/bin" DESTDIR="$t/dest" version=6.1.0-test \
        sh "$t/ota-hook" > "$t/stdout.txt" 2> "$t/stderr.txt"
}

run_hook; rc=$?
[ "$rc" = 0 ] && ok "hook exits 0 with the fixture list" || bad "hook exit $rc"

cat > "$t/expected.log" << EXP
copy_exec $t/bin/fxbash
copy_file file /usr/lib/unitotem/ota-engine.sh /usr/lib/unitotem/ota-engine.sh
copy_file file /etc/group /etc/group
copy_exec $t/bin/fxone
copy_exec $t/bin/fxtwo
copy_file file $t/lib/libfx.so.1 $t/lib/libfx.so.1
copy_file file $t/ti2/l/linux /usr/share/terminfo/l/linux
copy_file file $t/ti2/v/vt220 /usr/share/terminfo/v/vt220
manual_add_modules vfat nls_fx
manual_add_modules fxb
copy_exec $t/bin/fxefi
copy_exec $t/bin/fxgrub
manual_add_modules efivarfs
copy_file directory $t/grub/i386 $t/grub/i386
copy_exec $t/bin/nc
copy_exec $t/bin/reboot
EXP
diff "$t/expected.log" "$CALLS" > "$t/calls.diff" && ok "call log matches the fixture list" || { bad "call log differs"; cat "$t/calls.diff"; }

grep -qx "unitotem-ota hook: 'fxmissing' not found, skipping" "$t/stderr.txt" && ok "missing name warns" || bad "missing name warning absent"
[ "$(wc -l < "$t/stderr.txt")" = 1 ] && ok "no other warnings" || bad "unexpected stderr: $(cat "$t/stderr.txt")"
[ -f "$t/dest$t/bin/fxdd" ] && ok "real binary copied over the stub" || bad "real binary not copied"
[ "$(readlink "$t/dest/usr/sbin/unitotem-ota-engine")" = /usr/lib/unitotem/ota-engine.sh ] && ok "engine symlink" || bad "engine symlink missing"
[ "$(readlink "$t/dest/usr/sbin/reboot")" = "$t/bin/reboot" ] && ok "reboot symlink" || bad "reboot symlink missing"
[ "$(readlink "$t/dest/bin/nc")" = "$t/bin/nc" ] && ok "nc symlink" || bad "nc symlink missing"
[ -d "$t/dest/root/.ssh" ] && [ "$(stat -c %a "$t/dest/root/.ssh")" = 700 ] && ok "root/.ssh mode 700" || bad "root/.ssh"

# A directive the hook does not know stops the run with an error.
printf 'frob x\nbin fxone\n' > "$t/ota-initrd.list"
run_hook; rc=$?
[ "$rc" = 1 ] && [ ! -s "$CALLS" ] && ok "unknown directive stops the hook" || bad "unknown directive: rc $rc"

# Static checks on the real hook and list.
python3 -I - "$REPO" << 'PY' > "$t/static.txt" 2>&1
import re, sys
repo = sys.argv[1]
sys.path.insert(0, repo + "/unitotem/ninitrd")
import lists
entries = lists.read_list(repo + "/unitotem/files/ota-initrd.list")
names = sorted({a for _, args in entries for a in args})
# Command words and code-owned names the hook still uses (copy helpers, shell builtins, the ota-engine symlink, nc, reboot).
code_words = {"cp", "rm", "grep", "readlink", "dirname", "chmod", "ldd", "ln", "mkdir", "uname", "echo", "read",
              "nc", "reboot", "unitotem-ota-engine", "/usr/lib/unitotem/ota-engine.sh", "/usr/sbin/efibootmgr"}
hook = [l for l in open(repo + "/unitotem/files/ota-hook", encoding="utf-8") if not l.lstrip().startswith("#")]
offenders = []
for name in names:
    if name in code_words:
        continue
    pat = re.compile(r"(?<![A-Za-z0-9._+/-])" + re.escape(name) + r"(?![A-Za-z0-9._+/-])")
    if any(pat.search(l) for l in hook):
        offenders.append(name)
print("hook names checked:", len(names))
print("offenders:", ",".join(offenders) if offenders else "none")
sys.exit(1 if offenders else 0)
PY
[ $? = 0 ] && ok "no list name hardcoded in the hook ($(sed -n 1p "$t/static.txt"))" || { bad "hardcoded names: $(sed -n 2p "$t/static.txt")"; }

grep -q 'ota-initrd.list' "$REPO/unitotem/stage1-packages.sh" && grep -q 'ota-initrd.list' "$REPO/unitotem/stage1-recovery-initrd.sh" \
    && ok "both install sites ship the list" || bad "install site missing the list"
grep -Eq '^[[:space:]]*(install|cp)[[:space:]].*ota-initrd\.list' "$REPO/unitotem/stage2-configure.sh" && bad "stage2 must not install a second copy" || ok "stage2 does not install the list (it only passes the installed copy to the native slot initramfs builder)"
dash -n "$REPO/unitotem/files/ota-hook" && sh -n "$REPO/unitotem/files/ota-hook" && ok "hook syntax (dash, sh)" || bad "hook syntax"

# lists.py: the real list parses, a malformed one is rejected.
python3 -I "$REPO/unitotem/ninitrd/lists.py" "$REPO/unitotem/files/ota-initrd.list" > /dev/null && ok "lists.py parses the real list" || bad "lists.py real list"
printf 'bin a/../b\n' > "$t/bad.list"
python3 -I "$REPO/unitotem/ninitrd/lists.py" "$t/bad.list" > /dev/null 2>&1; [ $? = 1 ] && ok "lists.py rejects '..'" || bad "lists.py accepted '..'"
printf 'logo unitotem-logo-256x73\n' > "$t/bad.list"
python3 -I "$REPO/unitotem/ninitrd/lists.py" "$t/bad.list" > /dev/null 2>&1; [ $? = 1 ] && ok "lists.py rejects the retired logo directive" || bad "lists.py accepted logo"

[ "$fail" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail

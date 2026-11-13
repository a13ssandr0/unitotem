#!/bin/bash
# unitotem/check-engine-copy.sh on small cpio archives: identical copy, stale copy, no copy.
#   tools/release/test_check_engine_copy.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail=0
t=$(mktemp -d /tmp/test-engine-copy.XXXXXX) || exit 1
cd "$t" || exit 1
mkdir -p same/usr/lib/unitotem stale/usr/lib/unitotem none/usr/lib
printf 'engine v2\n' > engine.sh
cp engine.sh same/usr/lib/unitotem/ota-engine.sh
printf 'engine v1\n' > stale/usr/lib/unitotem/ota-engine.sh
printf 'x\n' > none/usr/lib/other
for d in same stale none; do ( cd $d && find . | cpio -o -H newc --quiet > ../$d.img ); done
CHK="$OLDPWD/unitotem/check-engine-copy.sh"
expect() { local name=$1 want=$2; shift 2; "$@" >/dev/null 2>&1; local rc=$?; if [ "$rc" = "$want" ]; then echo "PASS: $name"; else echo "FAIL: $name (exit $rc, wanted $want)"; fail=1; fi; }
expect "identical copy" 0 "$CHK" same.img engine.sh
expect "stale copy" 1 "$CHK" stale.img engine.sh
expect "no copy" 1 "$CHK" none.img engine.sh
expect "unreadable initramfs" 2 "$CHK" engine.sh engine.sh
cd /; python3 -I -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$t"
exit $fail

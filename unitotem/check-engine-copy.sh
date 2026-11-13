#!/bin/bash
# Is the OTA engine inside an initramfs the engine of the repository?
#   check-engine-copy.sh INITRD ENGINE.sh
# The initramfs carries a copy (usr/lib/unitotem/ota-engine.sh); stage 1 installs it and stage 1b/stage 2 refresh it. A copy from an older stage 1
# tarball runs the old fallback. Exit 0 identical, 1 different or absent, 2 the initramfs cannot be read.
set -uo pipefail
[ $# -eq 2 ] || { echo "usage: $0 INITRD ENGINE.sh" >&2; exit 2; }
exec python3 -I - "$1" "$2" <<'PY'
import filecmp, pathlib, subprocess, sys, tempfile
initrd, engine = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory(prefix='engine-copy-') as tmp:
    r = subprocess.run(['unmkinitramfs', initrd, tmp], capture_output=True, text=True)
    if r.returncode != 0:
        print('unmkinitramfs failed: %s' % r.stderr.strip(), file=sys.stderr); sys.exit(2)
    found = sorted(pathlib.Path(tmp).rglob('usr/lib/unitotem/ota-engine.sh'))
    if not found:
        print('no usr/lib/unitotem/ota-engine.sh in %s' % initrd, file=sys.stderr); sys.exit(1)
    if not all(filecmp.cmp(str(f), engine, shallow=False) for f in found):
        print('the ota-engine.sh in %s differs from %s' % (initrd, engine), file=sys.stderr); sys.exit(1)
print('engine copy identical')
PY

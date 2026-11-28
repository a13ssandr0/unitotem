#!/bin/bash
# Fixture test of unitotem/make-boot-tree.sh: unitotem-firmware.json (version, installed_at, files) with --firmware and --stage2.
# Every path is a tmp dir; the script runs with TMPDIR inside it. No system file is read or written.
#   bash tools/release/test_boot_tree_firmware.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TREE_SCRIPT="$HERE/../../unitotem/make-boot-tree.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/unitotem-boot-tree-firmware.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
export TMPDIR="$TMP"

FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

VERSION="1:1.20260915-1"
LEVEL="20261019055632"
EPOCH=$(date -u -d '2026-10-19 05:56:32' +%s)   # independent of the script's own conversion

# ---- fixtures: a firmware directory, the recovery set and the engine ----
FW="$TMP/fw"
mkdir -p "$FW"
for f in bootcode.bin start.elf fixup.dat start4.elf fixup4.dat start_x.elf bcm2710-rpi-3-b.dtb bcm2711-rpi-4-b.dtb LICENCE.broadcom; do
    printf 'firmware %s\n' "$f" > "$FW/$f"
done
printf 'kernel\n' > "$TMP/vmlinuz"
printf 'initrd, not a cpio archive\n' > "$TMP/initrd"
printf '#!/bin/sh\n# fixture engine\n' > "$TMP/engine"
TREE="$TMP/tree"

run_tree() {  # run_tree OUTDIR [extra args...]: the script with the common recovery arguments
    local out=$1; shift
    bash "$TREE_SCRIPT" --out "$out" --recovery-vmlinuz "$TMP/vmlinuz" --recovery-initrd "$TMP/initrd" \
        --level "$LEVEL" --engine "$TMP/engine" "$@"
}

# ---- build with --firmware and --firmware-version ----
if run_tree "$TREE" --firmware "$FW" --firmware-version "$VERSION" > "$TMP/run.log" 2>&1; then
    ok "make-boot-tree --firmware DIR --firmware-version V runs"
else
    bad "make-boot-tree --firmware DIR --firmware-version V runs"; cat "$TMP/run.log"
fi

JSON="$TREE/unitotem-firmware.json"
(cd "$TREE" && sha256sum bootcode.bin start.elf fixup.dat start4.elf fixup4.dat) > "$TMP/expected.sha"

# json parses, keys exact, version, integer installed_at, files = the five names with the sha256sum values, canonical form
if python3 -I - "$JSON" "$VERSION" "$EPOCH" "$TMP/expected.sha" > "$TMP/check.log" 2>&1 << 'PY'
import json
import sys

path, version, at, expected_file = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    raw = f.read()
data = json.loads(raw)
assert set(data) == {"version", "installed_at", "files"}, sorted(data)
assert data["version"] == version, data["version"]
assert type(data["installed_at"]) is int and data["installed_at"] == int(at), data["installed_at"]
expected = {}
with open(expected_file, encoding="utf-8") as f:
    for line in f:
        digest, name = line.split()
        expected[name] = digest
assert sorted(expected) == ["bootcode.bin", "fixup.dat", "fixup4.dat", "start.elf", "start4.elf"], sorted(expected)
assert data["files"] == expected, (data["files"], expected)
assert raw == json.dumps(data, sort_keys=True) + "\n", "not the canonical json.dumps form"
PY
then
    ok "unitotem-firmware.json: parses, version, installed_at, files = sha256sum of the five names"
else
    bad "unitotem-firmware.json content"; cat "$TMP/check.log"
fi

# the json is listed in boot-tree.sha256 with its own hash
if grep -q ' unitotem-firmware.json$' "$TREE/boot-tree.sha256" \
   && [ "$(cd "$TREE" && sha256sum unitotem-firmware.json)" = "$(grep ' unitotem-firmware.json$' "$TREE/boot-tree.sha256")" ]; then
    ok "unitotem-firmware.json is listed in boot-tree.sha256 with its hash"
else
    bad "unitotem-firmware.json is listed in boot-tree.sha256"
fi
if (cd "$TREE" && sha256sum -c --quiet boot-tree.sha256); then
    ok "boot-tree.sha256 verifies the whole tree"
else
    bad "boot-tree.sha256 verifies the whole tree"
fi
if [ ! -e "$TREE/start_x.elf" ]; then ok "start_x.elf left out"; else bad "start_x.elf left out"; fi

# ---- refusals ----
if run_tree "$TMP/tree-badver" --firmware "$FW" --firmware-version 'a b;x' > "$TMP/badver.log" 2>&1; then
    bad "a bad --firmware-version is refused"
else
    if grep -q 'not valid' "$TMP/badver.log"; then ok "a bad --firmware-version is refused"; else bad "a bad --firmware-version is refused (wrong message)"; fi
fi
if run_tree "$TMP/tree-nover" --firmware "$FW" > "$TMP/nover.log" 2>&1; then
    bad "--firmware without --firmware-version is refused"
else
    ok "--firmware without --firmware-version is refused"
fi

# ---- --stage2: the version is the raspi-firmware record of the dpkg status of the tarball ----
S2="$TMP/s2"
mkdir -p "$S2/boot" "$S2/var/lib/dpkg"
cp -r "$FW" "$S2/boot/firmware"
cat > "$S2/var/lib/dpkg/status" << 'EOF'
Package: libc6
Status: install ok installed
Version: 2.42-1

Package: raspi-firmware
Status: install ok installed
Version: 1:1.20260915-1
Description: Raspberry Pi boot firmware

Package: zlib1g
Status: install ok installed
Version: 1:1.3-1
EOF
tar -C "$S2" -czf "$TMP/stage2.tar.gz" ./boot/firmware ./var/lib/dpkg/status
if run_tree "$TMP/tree-s2" --stage2 "$TMP/stage2.tar.gz" > "$TMP/s2.log" 2>&1 \
   && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["version"]==sys.argv[2] else 1)' \
        "$TMP/tree-s2/unitotem-firmware.json" "$VERSION"; then
    ok "--stage2: version from the raspi-firmware stanza of the dpkg status"
else
    bad "--stage2: version from the raspi-firmware stanza of the dpkg status"; cat "$TMP/s2.log"
fi
if run_tree "$TMP/tree-s2b" --stage2 "$TMP/stage2.tar.gz" --firmware-version "$VERSION" > /dev/null 2>&1; then
    bad "--stage2 with --firmware-version is refused"
else
    ok "--stage2 with --firmware-version is refused"
fi

# a dpkg status without raspi-firmware is refused
mkdir -p "$TMP/s3/boot" "$TMP/s3/var/lib/dpkg"
cp -r "$FW" "$TMP/s3/boot/firmware"
printf 'Package: libc6\nStatus: install ok installed\nVersion: 2.42-1\n' > "$TMP/s3/var/lib/dpkg/status"
tar -C "$TMP/s3" -czf "$TMP/stage2-nofw.tar.gz" ./boot/firmware ./var/lib/dpkg/status
if run_tree "$TMP/tree-s3" --stage2 "$TMP/stage2-nofw.tar.gz" > "$TMP/s3.log" 2>&1; then
    bad "--stage2 without a raspi-firmware record is refused"
else
    ok "--stage2 without a raspi-firmware record is refused"
fi

echo "boot tree firmware test: $FAILS failure(s)"
[ "$FAILS" -eq 0 ]

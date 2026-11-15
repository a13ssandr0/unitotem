#!/usr/bin/env python3
"""Host-side test of cmd_blank_part (deploy/script/ota-engine.sh), the ROOT_B action of the deploy:
the first MiB of the partition is zeroed and nothing after it is written; a missing label or partition is refused; the
engine dispatches `blank-part` and no longer has `format-part`. Functions are cut out of the real script text, the partition
is a regular file standing for the block device. Temporary directories only.

  python3 tools/release/test_deploy_blank_part.py
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ENG = open(os.path.join(ROOT, "deploy/script/ota-engine.sh")).read()
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def fn(text, name):
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.S | re.M) \
        or re.search(r"^%s\(\) \{.*\}\n" % re.escape(name), text, re.M)
    if not m:
        raise SystemExit("FAIL: function %s not found" % name)
    return m.group(0)


check("engine dispatches blank-part to cmd_blank_part", "blank-part)             cmd_blank_part" in ENG)
check("engine has no format-part subcommand or function", "format-part" not in ENG and "cmd_format_part" not in ENG)

blank = fn(ENG, "cmd_blank_part")
OLD_B = '    [ -b "$part_dev" ] || fail "partition not found: $part_dev"'
check("harness: cmd_blank_part has the -b device test exactly once (replaced below)", blank.count(OLD_B) == 1)
blank = blank.replace(OLD_B, '    [ -e "$part_dev" ] || fail "partition not found: $part_dev"')
funcs = fn(ENG, "parse_args") + fn(ENG, "need") + fn(ENG, "pdev_target") + blank
HARNESS = (
    'declare -A ARG\n'
    'log() { echo "unitotem-ota: $*" >&2; }\n'
    'fail() { echo "unitotem-ota: ERROR: $*" >&2; exit 1; }\n'
    'resolve_disk() { echo "$1"; }\n'
)


def run(disk, args):
    script = HARNESS + funcs + "\ncmd_blank_part " + args + "\n"
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)


with tempfile.TemporaryDirectory() as td:
    MIB = 1048576
    dev = os.path.join(td, "disk")  # pdev_target("<dev>", 3) = "<dev>3" for a plain name: the partition file is disk3
    part = dev + "3"
    with open(part, "wb") as f:
        f.write(b"\xAB" * (4 * MIB))  # stale ext4-like content in every MiB
    r = run(dev, "--disk %s --part 3 --label ROOT_B" % dev)
    check("blank-part exits 0", r.returncode == 0, r.stderr)
    check("blank-part prints UNITOTEM_PART_BLANKED=3", "UNITOTEM_PART_BLANKED=3" in r.stdout, r.stdout)
    data = open(part, "rb").read()
    check("first MiB is zero", data[:MIB] == b"\0" * MIB)
    check("everything after the first MiB is untouched", data[MIB:] == b"\xAB" * (3 * MIB))
    check("the blank partition is logged as cloned at the first boot", "cloned from ROOT_A at the first boot" in r.stderr, r.stderr)

    r = run(dev, "--disk %s --part 3" % dev)
    check("missing --label is refused", r.returncode != 0 and "--label required" in r.stderr, r.stderr)
    r = run(dev, "--disk %s --part 9 --label ROOT_B" % dev)
    check("missing partition is refused and nothing is written", r.returncode != 0 and "partition not found" in r.stderr)

    check("refused runs left the partition as it was", open(part, "rb").read()[:MIB] == b"\0" * MIB)

print("%d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)

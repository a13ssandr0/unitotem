#!/usr/bin/env python3
"""Host-side test of the boot picture mode recorded by the deploy (unitotem_gfx in the target's grubenv).
drm_gfx and gfx_valid are cut out of deploy/script/ota-engine.sh and run in bash on a fake sysfs tree; the copy in
deploy/script/remote-deploy.sh (the running system's probe) must be identical. trial_grubenv_kv and grubenv_write run on
a temporary grubenv made with grub-editenv (SKIP without it). Nothing outside a temporary directory is read or written.

  python3 tools/release/test_deploy_gfx_record.py
"""
import os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ENG = open(os.path.join(ROOT, "deploy/script/ota-engine.sh")).read()
DEP = open(os.path.join(ROOT, "deploy/script/remote-deploy.sh")).read()
GRUBENV_EDIT = shutil.which("grub-editenv")
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond:
        ok += 1
        print("PASS:", name)
    else:
        fail += 1
        print("FAIL:", name, extra)


def fn(text, name):
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.S | re.M)
    if not m:
        raise SystemExit("FAIL: function %s not found" % name)
    return m.group(0)


def bash(src, args=()):
    p = subprocess.run(["bash", "-c", src, "_"] + list(args), capture_output=True, text=True, timeout=30)
    return p.returncode, p.stdout, p.stderr


PROBE_FUNCS = fn(ENG, "gfx_valid") + fn(ENG, "drm_gfx")

# The running system's copy (remote-deploy.sh, sent in the probe heredoc) is the same text.
check("remote probe has the same gfx_valid as the engine", fn(DEP, "gfx_valid") == fn(ENG, "gfx_valid"))
check("remote probe has the same drm_gfx as the engine", fn(DEP, "drm_gfx") == fn(ENG, "drm_gfx"))
check("remote probe prints GFX", 'echo "GFX: $(drm_gfx)"' in DEP)
check("engine probe prints UNITOTEM_GFX", 'echo "UNITOTEM_GFX=$gfx"' in ENG)
check("set-trial-boot receives --gfx from the host, validated",
      "--layout ab --gfx '${gfx}'" in DEP and '[[ "$gfx" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]] || gfx=""' in DEP)
check("set-trial-boot writes the kept variables with the mode", 'mapfile -t keep < <(trial_grubenv_kv "$ge"' in ENG)

TMP = tempfile.mkdtemp(prefix="grubimpl-h7-")


def conn(base, name, status, modes=None):
    d = os.path.join(base, name)
    os.makedirs(d)
    with open(os.path.join(d, "status"), "w") as f:
        f.write(status + "\n")
    if modes is not None:
        with open(os.path.join(d, "modes"), "w") as f:
            f.write(modes)


def drm(base):
    rc, out, err = bash("set -euo pipefail\n" + PROBE_FUNCS + '\ndrm_gfx "$1"', [base])
    check("drm_gfx exits 0 (%s)" % base, rc == 0, err)
    return out.rstrip("\n")


case = [0]


def sysfs(connectors):
    case[0] += 1
    base = os.path.join(TMP, "sys%02d" % case[0], "drm")
    os.makedirs(base)
    for c in connectors:
        conn(base, *c)
    return base


base = sysfs([("card0-HDMI-A-1", "connected", "1920x1080\n1280x720\n")])
check("single connected display: first mode", drm(base) == "1920x1080")

base = sysfs([("card0-HDMI-A-1", "connected", "1280x720\n"), ("card1-DP-1", "connected", "1920x1200\n")])
check("two connected: sorted first wins", drm(base) == "1280x720")

base = sysfs([("card0-HDMI-A-1", "connected", "1920x1080\n"), ("card0-eDP-1", "connected", "1366x768\n")])
check("eDP wins over an HDMI connector sorted before it", drm(base) == "1366x768")

base = sysfs([("card0-eDP-1", "disconnected", "1366x768\n"), ("card0-HDMI-A-1", "connected", "1920x1080\n")])
check("disconnected eDP is skipped", drm(base) == "1920x1080")

base = sysfs([("card0-HDMI-A-1", "disconnected", "1920x1080\n"), ("card1-DP-1", "disconnected", "1920x1200\n")])
check("none connected: nothing", drm(base) == "")

base = sysfs([("card0-eDP-1", "connected", None), ("card0-HDMI-A-1", "connected", "1920x1080\n")])
check("connected eDP without modes: nothing (no fallback to another connector)", drm(base) == "")

for bad in ["abc\n", "1920x1080x\n", "1920x\n", "99999x99999\n", "100x100\n", "0x0\n", "19200x1080\n",
            "8193x1000\n", "1000x199\n", "1920x1080 \n", "\n", ""]:
    base = sysfs([("card0-HDMI-A-1", "connected", bad)])
    check("garbage mode %r: nothing" % bad, drm(base) == "")

for hostile, want in [("1920x1080;touch /x\n", ""), ("$(id)x1080\n", ""), ("1920x1080\nrm -rf /\n", "1920x1080"),
                      ("1920x1080'\"\n", ""),
                      # bash drops a NUL byte in $(...): the rest is a valid mode
                      ("1920x1080\x00\n", "1920x1080")]:
    base = sysfs([("card0-HDMI-A-1", "connected", hostile)])
    check("hostile mode %r" % hostile, drm(base) == want, "got %r" % drm(base))

base = os.path.join(TMP, "no-such-drm-dir")
check("missing sysfs directory: nothing", drm(base) == "")

# --- grubenv: trial_grubenv_kv + grubenv_write on a temporary block -----------------------------------------
if not GRUBENV_EDIT:
    print("SKIP: grub-editenv not installed (grubenv checks not run)")
else:
    GW = (fn(ENG, "grubenv_write") + fn(ENG, "trial_grubenv_kv") + PROBE_FUNCS)
    WRITE_SRC = ("set -euo pipefail\nfail() { echo \"fail: $*\" >&2; exit 1; }\n" + GW +
                 '\nmapfile -t KEEP < <(trial_grubenv_kv "$1" "${2:-}")\n'
                 'grubenv_write "$1" "saved_entry=ota-recovery" "next_entry=slot-a" "${KEEP[@]}"\n')

    def make_env(path, extra=()):
        subprocess.run([GRUBENV_EDIT, path, "create"], check=True)
        subprocess.run([GRUBENV_EDIT, path, "set", "foo=bar", *extra], check=True)

    def listing(path):
        out = subprocess.run([GRUBENV_EDIT, path, "list"], capture_output=True, text=True, check=True).stdout
        return out.splitlines()

    def run_write(path, gfx):
        rc, out, err = bash(WRITE_SRC, [path, gfx])
        return rc, err

    d = os.path.join(TMP, "env")
    os.makedirs(d)

    p = os.path.join(d, "valid")
    make_env(p)
    rc, err = run_write(p, "1920x1080")
    lines = listing(p)
    check("valid mode written (%s)" % err, rc == 0 and "unitotem_gfx=1920x1080" in lines, str(lines))
    check("other keys preserved", "foo=bar" in lines and "saved_entry=ota-recovery" in lines and "next_entry=slot-a" in lines)
    check("grubenv is 1024 bytes", os.path.getsize(p) == 1024)

    p = os.path.join(d, "replace")
    make_env(p, ["unitotem_gfx=1280x720"])
    run_write(p, "1920x1080")
    lines = listing(p)
    check("existing unitotem_gfx replaced, not duplicated",
          lines.count("unitotem_gfx=1920x1080") == 1 and not any(x.startswith("unitotem_gfx=1280") for x in lines), str(lines))

    p = os.path.join(d, "unknown")
    make_env(p)
    run_write(p, "")
    lines = listing(p)
    check("unknown mode: key unset", not any(x.startswith("unitotem_gfx=") for x in lines) and "foo=bar" in lines, str(lines))

    p = os.path.join(d, "unknown-keep")
    make_env(p, ["unitotem_gfx=1280x720"])
    run_write(p, "")
    check("unknown mode keeps an existing unitotem_gfx", "unitotem_gfx=1280x720" in listing(p))

    ref = os.path.join(d, "ref")
    make_env(ref)
    run_write(ref, "")
    ref_bytes = open(ref, "rb").read()
    for hostile in ["1920x1080;touch /x", "$(id)", "1920x1080\nfoo=evil", "100x100", "9999x9999", "1920x1080 ", "x",
                    "1920x1080'", "../../etc"]:
        p = os.path.join(d, "hostile")
        make_env(p)
        rc, err = run_write(p, hostile)
        check("hostile mode %r leaves the grubenv byte-identical to an unknown mode" % hostile,
              rc == 0 and open(p, "rb").read() == ref_bytes, err)

shutil.rmtree(TMP)
print("\n%d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)

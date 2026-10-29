#!/usr/bin/env python3
"""Test of unitotem-boot-orientation: the command-line rewriting and both backends on temporary directories (the GRUB one with a stub grub-editenv).

  python3 tools/release/test_boot_orientation.py
"""
import importlib.machinery, importlib.util, io, json, os, stat, sys, tempfile, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def load(env):
    os.environ.update(env)
    loader = importlib.machinery.SourceFileLoader("bo", os.path.join(ROOT, "unitotem/files/unitotem-boot-orientation"))
    spec = importlib.util.spec_from_loader("bo", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
    return m


def run(m, argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        rc = m.main(argv)
    return rc, (json.loads(buf.getvalue()) if buf.getvalue().strip() else None)


with tempfile.TemporaryDirectory() as td:
    base = "console=tty1 root=LABEL=ROOT_A rootwait ro quiet unitotem.slot=a"
    m = load({"UNITOTEM_BOOTFS": os.path.join(td, "fw"), "UNITOTEM_ESP": os.path.join(td, "esp"), "UNITOTEM_GRUBENV": os.path.join(td, "esp/grubenv")})
    # ---- merge
    check("adds the token when the connector has none", m.merge(base, "HDMI-A-1", "right") == base + " video=HDMI-A-1:panel_orientation=right_side_up")
    check("keeps the mode of an existing video= token", m.merge(base + " video=HDMI-A-1:1920x1080@60D", "HDMI-A-1", "left") == base + " video=HDMI-A-1:1920x1080@60D,panel_orientation=left_side_up")
    check("replaces an earlier orientation", m.merge(base + " video=HDMI-A-1:panel_orientation=right_side_up", "HDMI-A-1", "inverted") == base + " video=HDMI-A-1:panel_orientation=upside_down")
    check("normal removes it and drops an empty token", m.merge(base + " video=HDMI-A-1:panel_orientation=right_side_up", "HDMI-A-1", "normal") == base)
    check("normal keeps the mode", m.merge(base + " video=HDMI-A-1:1920x1080@60D,panel_orientation=right_side_up", "HDMI-A-1", "normal") == base + " video=HDMI-A-1:1920x1080@60D")
    check("other connectors are untouched", m.merge(base + " video=DP-2:panel_orientation=left_side_up", "HDMI-A-1", "right") == base + " video=DP-2:panel_orientation=left_side_up video=HDMI-A-1:panel_orientation=right_side_up")
    check("normal on a connector without a token changes nothing", m.merge(base, "HDMI-A-1", "normal") == base)
    check("read: connectors and names", m.read_orientation(base + " video=DP-2:panel_orientation=left_side_up video=HDMI-A-1:1920x1080,panel_orientation=upside_down") == {"DP-2": "left", "HDMI-A-1": "inverted"})

    # ---- Raspberry Pi backend: both slots
    for s in "ab":
        os.makedirs(os.path.join(td, "fw/slot" + s))
        open(os.path.join(td, "fw/slot%s/cmdline.txt" % s), "w").write(base.replace("slot=a", "slot=" + s) + " video=HDMI-A-1:1920x1080@60D\n")
    rc, out = run(m, ["set", "HDMI-A-1", "right"])
    check("rpi: set exits 0 and names both files", rc == 0 and len(out["files"]) == 2, out)
    check("rpi: both slots carry the orientation, the rest is intact", all(
        open(os.path.join(td, "fw/slot%s/cmdline.txt" % s)).read().strip() == base.replace("slot=a", "slot=" + s) + " video=HDMI-A-1:1920x1080@60D,panel_orientation=right_side_up" for s in "ab"))
    check("rpi: get", run(m, ["get", "HDMI-A-1"])[1] == {"connector": "HDMI-A-1", "orientation": "right"})
    check("rpi: get without a connector lists them", run(m, ["get"])[1] == {"orientations": {"HDMI-A-1": "right"}})
    check("rpi: no temporary file left", not [f for f in os.listdir(os.path.join(td, "fw/slota")) if f != "cmdline.txt"])
    run(m, ["set", "HDMI-A-1", "normal"])
    check("rpi: normal restores the original line", open(os.path.join(td, "fw/slotb/cmdline.txt")).read().strip().endswith("video=HDMI-A-1:1920x1080@60D"))

    # ---- GRUB backend with a stub grub-editenv (a text file of name=value lines)
    import shutil
    shutil.rmtree(os.path.join(td, "fw"))
    os.makedirs(os.path.join(td, "esp")); open(os.path.join(td, "esp/grubenv"), "w").write("saved_entry=slot-a\n")
    bindir = os.path.join(td, "bin"); os.makedirs(bindir)
    stub = os.path.join(bindir, "grub-editenv")
    open(stub, "w").write('''#!/bin/sh
f="$1"; op="$2"; shift 2
case "$op" in
  list) cat "$f" ;;
  set) k="${1%%=*}"; grep -v "^$k=" "$f" > "$f.n"; echo "$1" >> "$f.n"; mv "$f.n" "$f" ;;
  unset) grep -v "^$1=" "$f" > "$f.n"; mv "$f.n" "$f" ;;
esac
''')
    os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
    m = load({"UNITOTEM_BOOTFS": os.path.join(td, "fw"), "UNITOTEM_ESP": os.path.join(td, "esp"), "UNITOTEM_GRUBENV": os.path.join(td, "esp/grubenv")})
    check("grub: backend detected", m.backend() == "grub")
    run(m, ["set", "DP-2", "left"]); run(m, ["set", "HDMI-A-1", "inverted"])
    env = open(os.path.join(td, "esp/grubenv")).read()
    check("grub: the variable holds one token per connector, other variables stay", "saved_entry=slot-a" in env and
          "unitotem_video=video=DP-2:panel_orientation=left_side_up video=HDMI-A-1:panel_orientation=upside_down" in env, env)
    check("grub: get", run(m, ["get", "DP-2"])[1] == {"connector": "DP-2", "orientation": "left"})
    run(m, ["set", "DP-2", "normal"]); run(m, ["set", "HDMI-A-1", "normal"])
    check("grub: the variable is removed when nothing is left", "unitotem_video" not in open(os.path.join(td, "esp/grubenv")).read())

    # ---- arguments
    check("bad orientation is refused", run(m, ["set", "HDMI-A-1", "sideways"])[0] == 2)
    check("bad connector is refused", run(m, ["set", "HDMI A 1; rm", "right"])[0] == 2)
    check("no arguments is refused", run(m, [])[0] == 2)

print("\n%d passed, %d failed" % (ok, fail)); sys.exit(1 if fail else 0)

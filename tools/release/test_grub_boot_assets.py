#!/usr/bin/env python3
"""Test of grub-boot-assets.py: picture sizes and mode, the Plymouth layout (centred wordmark and ring, text line below it), and CLI validation, on the real theme and font.

  python3 tools/release/test_grub_boot_assets.py
"""
import importlib.machinery, importlib.util, os, subprocess, sys, tempfile, time

from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPT = os.path.join(ROOT, "unitotem/grub-boot-assets.py")
THEME = os.path.join(ROOT, "unitotem-manager/plymouth/unitotem")
FONT = os.path.join(ROOT, "unitotem-manager/manager/plugins/unitotem_viewer/static/NotoSans.ttf")
MODES = ["1280x800", "1920x1080", "1920x1200", "3840x2160", "1366x768"]
VERSION = "2026.12~dev2"
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def load_module():
    loader = importlib.machinery.SourceFileLoader("gba", SCRIPT)
    spec = importlib.util.spec_from_loader("gba", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
    return m


def cli(*args):
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True)


def ink_bbox(im):
    # Bounding box of pixels brighter than half intensity; right and bottom are exclusive.
    return im.convert("L").point(lambda v: 255 if v > 127 else 0).getbbox()


def alpha_bbox(im):
    # Same half-coverage box for the alpha channel of a source PNG.
    return im.split()[3].point(lambda v: 255 if v > 127 else 0).getbbox()


gba = load_module()
t0 = time.time()
with tempfile.TemporaryDirectory() as td:
    logo_dir = os.path.join(td, "logo")
    slot_dir = os.path.join(td, "slot")
    modes_arg = ",".join(MODES)

    # ---- generation
    r = cli("logo", "--theme", THEME, "--out", logo_dir, "--modes", modes_arg)
    check("logo command exits 0", r.returncode == 0, r.stderr)
    check("logo summary line", r.stdout == "%d pictures in %s\n" % (len(MODES), logo_dir), repr(r.stdout))
    r = cli("slot", "--theme", THEME, "--font", FONT, "--version", VERSION, "--out", slot_dir, "--modes", modes_arg)
    check("slot command exits 0", r.returncode == 0, r.stderr)
    check("slot summary line", r.stdout == "%d pictures in %s\n" % (2 * len(MODES), slot_dir), repr(r.stdout))
    expected_logo = {"%dx%d.png" % tuple(map(int, m.split("x"))) for m in MODES}
    expected_slot = {"boot-%s-%s.png" % (s, m) for s in ("a", "b") for m in MODES}
    check("logo file names", set(os.listdir(logo_dir)) == expected_logo, str(sorted(os.listdir(logo_dir))))
    check("slot file names", set(os.listdir(slot_dir)) == expected_slot, str(sorted(os.listdir(slot_dir))))
    check("no temporary files left", not any(n.startswith(".tmp") for n in os.listdir(logo_dir) + os.listdir(slot_dir)))

    for mode in MODES:
        w, h = map(int, mode.split("x"))
        logo = Image.open(os.path.join(logo_dir, "%dx%d.png" % (w, h)))
        slot_a = Image.open(os.path.join(slot_dir, "boot-a-%s.png" % mode))
        slot_b = Image.open(os.path.join(slot_dir, "boot-b-%s.png" % mode))

        for name, im in (("logo", logo), ("slot a", slot_a), ("slot b", slot_b)):
            check("%s %s size and mode RGB" % (name, mode), im.size == (w, h) and im.mode == "RGB", "%s %s" % (im.size, im.mode))

        # The wordmark image box is centred on the screen (Plymouth does the same).
        wm, _ring, wx, wy = gba.geometry(THEME, w, h)
        check("%s wordmark box width is 0.601 W" % mode, abs(wm.width - 0.601 * w) <= 1, "box width %d" % wm.width)
        check("%s wordmark box horizontally centred" % mode, abs(wx - (w - wx - wm.width)) <= 1, "x %d" % wx)
        check("%s wordmark box vertically centred" % mode, abs((wy + wm.height / 2) - h / 2) <= 1, "y %d height %d" % (wy, wm.height))
        # The ink inside the artwork has its own margins: compare the scaled ink box with the source PNG.
        src = next(t for t in gba.TIERS if Image.open(os.path.join(THEME, "wordmark-%d.png" % t)).width >= int(0.601 * w))
        src_img = Image.open(os.path.join(THEME, "wordmark-%d.png" % src)).convert("RGBA")
        sl, _st, sr, _sb = alpha_bbox(src_img)
        k = wm.width / src_img.width
        left, _top, right, _bottom = ink_bbox(logo)
        check("%s wordmark ink width matches artwork" % mode, abs((right - left) - (sr - sl) * k) <= 2,
              "ink %d expected %.1f" % (right - left, (sr - sl) * k))
        check("%s wordmark ink margins match artwork" % mode,
              abs((left - (w - right)) - (sl - (src_img.width - sr)) * k) <= 2,
              "ink margins %d/%d" % (left, w - right))

        wm_bottom = wy + wm.height
        for name, slot in (("slot a", slot_a), ("slot b", slot_b)):
            d = ImageChops.difference(logo, slot)
            check("%s %s rows above wordmark bottom identical" % (name, mode), d.crop((0, 0, w, wm_bottom)).getbbox() is None)
            tb = d.getbbox()
            check("%s %s text line found" % (name, mode), tb is not None)
            if tb is None:
                continue
            tl, tt, tr, tbot = tb
            check("%s %s text horizontally centred" % (name, mode), abs(tl - (w - tr)) <= 3, "left %d right-margin %d" % (tl, w - tr))
            check("%s %s text below wordmark" % (name, mode), tt >= wm_bottom, "text top %d wordmark bottom %d" % (tt, wm_bottom))
        check("%s slot a and b differ" % mode, ImageChops.difference(slot_a, slot_b).getbbox() is not None)

    # ---- bad input: one line on stderr, exit 2
    r = cli("slot", "--theme", THEME, "--font", FONT, "--version", VERSION, "--out", os.path.join(td, "bad"), "--modes", "12x3")
    check("bad mode exits 2", r.returncode == 2, str(r.returncode))
    check("bad mode one stderr line", len(r.stderr.strip().splitlines()) == 1, repr(r.stderr))
    r = cli("slot", "--theme", THEME, "--font", FONT, "--version", "a b;", "--out", os.path.join(td, "bad"), "--modes", "1280x800")
    check("bad version exits 2", r.returncode == 2, str(r.returncode))
    r = cli("slot", "--theme", THEME, "--font", os.path.join(td, "missing.ttf"), "--version", VERSION, "--out", os.path.join(td, "bad"), "--modes", "1280x800")
    check("missing font exits 2", r.returncode == 2, str(r.returncode))
    check("missing font not created output", not os.path.exists(os.path.join(td, "bad")))
    r = cli("logo", "--theme", os.path.join(td, "notheme"), "--out", os.path.join(td, "bad"))
    check("missing theme exits 2", r.returncode == 2, str(r.returncode))

    elapsed = time.time() - t0
    size = sum(os.path.getsize(os.path.join(d, n)) for d in (logo_dir, slot_dir) for n in os.listdir(d))
    print("INFO: run time %.1f s, output %d bytes" % (elapsed, size))

print("RESULT: %d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)

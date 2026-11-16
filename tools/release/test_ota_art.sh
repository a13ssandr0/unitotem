#!/bin/bash
# ota_art (deploy/script/ota-engine.sh) against a small terminal model. The art is drawn above the whiptail dialog only when
# it fits (height + one blank row above the dialog, width within the columns), centred horizontally and vertically in the free
# rows above the dialog, in bold white on blue, with the cursor saved and restored. Output is ASCII only.
# Cases: 8x16 and 16x32 consoles from 640x480 to 3840x2160, the fit boundaries, a console too small to draw in, and the
# OTA_CONSOLE_SIZE path. Nothing outside the test folder is written.
#   tools/release/test_ota_art.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD
t=$(mktemp -d "$REPO/work/screen/scr-art-test.XXXXXX") || exit 1
cleanup() { python3 -I -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$t"; }
trap cleanup EXIT

python3 -I - "$REPO" "$t" << 'PY'
import os
import re
import subprocess
import sys

repo, t = sys.argv[1], sys.argv[2]
ENGINE = os.path.join(repo, "deploy/script/ota-engine.sh")
src = open(ENGINE, encoding="utf-8").read()

# The art and its function, cut from the engine: the dialog constants and the lines from ota_art's comment to cmd_serve_fallback.
head = src[src.index("OTA_DIALOG_ROWS=14\n"):]
head = head[:head.index("OTA_DIALOG_COLS=72\n") + len("OTA_DIALOG_COLS=72\n")]
body = src[src.index("# ota_art draws"):]
body = body[:body.index("cmd_serve_fallback() {")]
lib = os.path.join(t, "lib.sh")
open(lib, "w", encoding="utf-8").write(head + body)

# The art as the engine stores it (the here-doc of ota_art_text).
m = re.search(r"<<'EOF'\n(.*?)\nEOF\n", body, re.S)
art = m.group(1).split("\n")
ART_H = len(art)
ART_W = max(len(line) for line in art)
DH, DW = 14, 72  # OTA_DIALOG_ROWS, OTA_DIALOG_COLS

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else " " + detail))


def run_art(tag, args=None, env_size=None):
    out = os.path.join(t, f"out-{tag}.ans")
    env = dict(os.environ, OTA_ART_OUT=out)
    env.pop("OTA_CONSOLE_SIZE", None)
    if env_size:
        env["OTA_CONSOLE_SIZE"] = env_size
    argv = ["bash", "-c", '. "$1"; shift; ota_art "$@"', "_", lib] + [str(a) for a in (args or [])]
    res = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=20)
    data = open(out, "rb").read() if os.path.exists(out) else b""
    return res.returncode, data


def render(data, rows, cols):
    """Terminal model: cursor positioning (CUP), save/restore (ESC 7 / ESC 8), SGR kept per cell, ASCII text."""
    grid = [[(" ", None) for _ in range(cols)] for _ in range(rows)]
    r = c = 0
    saved = None
    attr = None
    text = data.decode("ascii")
    tok = re.compile(r"\x1b7|\x1b8|\x1b\[(\d+);(\d+)H|\x1b\[([\d;]*)m|(.)", re.S)
    pos = 0
    while pos < len(text):
        mm = tok.match(text, pos)
        if not mm:
            raise ValueError(f"unparsed at {pos}")
        pos = mm.end()
        s = mm.group(0)
        if s == "\x1b7":
            saved = (r, c)
        elif s == "\x1b8":
            r, c = saved
        elif mm.group(1) is not None:
            r, c = int(mm.group(1)) - 1, int(mm.group(2)) - 1
            if not (0 <= r < rows and 0 <= c < cols):
                raise ValueError(f"cursor out of the console: {r + 1};{c + 1}")
        elif mm.group(3) is not None:
            attr = mm.group(3)
        else:
            if not (0 <= r < rows and 0 <= c < cols):
                raise ValueError(f"text out of the console at {r + 1};{c + 1}")
            grid[r][c] = (s, attr)
            c += 1
    return grid


def expect_draw(rows, cols, dh, dw):
    if rows <= dh or cols <= 0:
        return False
    top = (rows - dh) // 2  # 0-based top row of the dialog (newt centring): rows 1..top are above it
    return ART_H + 1 <= top and ART_W <= cols


def check_case(tag, rows, cols, dh=DH, dw=DW, args=None, env_size=None):
    rc, data = run_art(tag, args if args is not None else [rows, cols, dh, dw], env_size)
    want = expect_draw(rows, cols, dh, dw)
    check(f"{tag}: exit 0", rc == 0, f"rc={rc}")
    check(f"{tag}: ASCII output only (bytes < 0x80)", all(b < 0x80 for b in data))
    if not want:
        check(f"{tag}: draws nothing ({ART_H + 1} rows + blank do not fit above row {(rows - dh) // 2})",
              data == b"", f"{len(data)} bytes")
        return
    check(f"{tag}: draws the art ({ART_H} rows, {ART_W} columns)", len(data) > 0)
    check(f"{tag}: cursor saved first and restored last",
          data.startswith(b"\x1b7") and data.endswith(b"\x1b8") and data.count(b"\x1b7") == data.count(b"\x1b8") == 1)
    grid = render(data, rows, cols)
    top = (rows - dh) // 2  # 1-based last row above the dialog
    cells = [(r, c, ch, a) for r in range(rows) for c in range(cols) for ch, a in [grid[r][c]] if ch != " "]
    check(f"{tag}: art text present", len(cells) > 0)
    rs = sorted({r + 1 for r, _, _, _ in cells})
    cs = [c for _, c, _, _ in cells]
    check(f"{tag}: art rows are contiguous and {ART_H} tall",
          rs == list(range(rs[0], rs[-1] + 1)) and len(rs) == ART_H, f"rows={rs}")
    check(f"{tag}: art entirely above the dialog with a blank row before it (art ends at row {rs[-1]}, dialog starts at row {top + 1})",
          rs[-1] <= top - 1 and all(grid[top - 1][c][0] == " " for c in range(cols)))
    check(f"{tag}: art within the columns", min(cs) >= 0 and max(cs) < cols)
    left, right = min(cs), cols - max(cs) - 1
    check(f"{tag}: horizontally centred (margins {left} and {right})", abs(left - right) <= 1)
    top_free, bottom_free = rs[0] - 1, top - rs[-1]
    check(f"{tag}: vertically centred in the rows above the dialog (free {top_free} above, {bottom_free} below)",
          abs(top_free - bottom_free) <= 2)
    check(f"{tag}: a blank row above the art when there is room", top_free >= 1 or top - ART_H - 1 < 2)
    check(f"{tag}: bold white on blue (1;37;44) on every art cell",
          all(a == "1;37;44" for _, _, _, a in cells), f"attrs={sorted({a for *_, a in cells})}")
    check(f"{tag}: nothing drawn on or below the dialog",
          all(r + 1 <= top for r, _, _, _ in cells))


# 8x16 cells (rows = H/16, cols = W/8) and 16x32 cells (rows = H/32, cols = W/16)
check_case("640x480-8x16", 30, 80)
check_case("1024x768-8x16", 48, 128)
check_case("1366x768-8x16", 48, 170)
check_case("1920x1080-8x16", 67, 240)
check_case("3840x2160-8x16", 135, 480)
check_case("1920x1080-16x32", 33, 120)
check_case("3840x2160-16x32", 67, 240)

# Fit boundaries: top = (rows - 14) / 2; the art needs top >= height + 1
check_case("fit-exact-rows26", 26, 80)
check_case("fit-one-short-rows25", 25, 80)
check_case("fit-width-exact", 30, ART_W)
check_case("fit-width-short", 30, ART_W - 1)

# Consoles that must draw nothing
check_case("640x480-16x32-no-room", 15, 40)
check_case("small-20x60", 20, 60)
check_case("dialog-fills-console", 14, 80)

# The size from OTA_CONSOLE_SIZE when no size is given
rc, data = run_art("env-size", args=[], env_size="30 80")
check("env-size: exit 0 and the art drawn for 30x80", rc == 0 and len(data) > 0)

print(f"test_ota_art: {len(PASS)} passed, {len(FAIL)} failed")
sys.exit(1 if FAIL else 0)
PY

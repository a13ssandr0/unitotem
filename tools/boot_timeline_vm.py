#!/usr/bin/env python3
"""Screendump timeline of a QEMU boot: QMP capture, BLACK/LIT classification, summary.

Driven by tools/boot-timeline-vm.sh (which starts and stops the QEMU).
Needs PIL. Standard library otherwise.
"""
import argparse
import csv
import json
import math
import os
import re
import socket
import sys
import time

from PIL import Image, ImageDraw

THUMB = (160, 120)       # grayscale grid for diff and mean luma
CHANGE_DIFF = 0.5        # mean abs diff (0-255) above which a frame is CHANGED
PROBE_TICKS = 10         # auto format: alternate ppm/png for the first ticks
FRAME_RE = re.compile(r"t_(\d{7})\.(ppm|png)$")


class QmpError(RuntimeError):
    pass


class Qmp:
    """Minimal QMP client over a unix socket, every call bounded by a timeout."""

    def __init__(self, path, timeout=5.0):
        self.path = path
        self.timeout = timeout
        self.sock = None
        self.buf = b""

    def close(self):
        if self.sock:
            self.sock.close()
        self.sock = None
        self.buf = b""

    def connect(self, wait_s):
        deadline = time.monotonic() + wait_s
        while True:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(self.timeout)
                s.connect(self.path)
                self.sock = s
                self._read_msg()  # greeting
                self.call("qmp_capabilities")
                return
            except (OSError, RuntimeError):
                self.close()
                if time.monotonic() > deadline:
                    raise RuntimeError("QMP socket not ready: " + self.path)
                time.sleep(0.2)

    def _read_msg(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise OSError("QMP connection closed")
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return json.loads(line)

    def call(self, cmd, **args):
        msg = {"execute": cmd}
        if args:
            msg["arguments"] = args
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            m = self._read_msg()
            if "event" in m:
                continue
            if "return" in m:
                return m["return"]
            if "error" in m:
                raise QmpError(m["error"].get("desc", "QMP error"))


def load_rgb(path):
    with Image.open(path) as im:
        return im.convert("RGB")


def analyze_file(path):
    """Return (max_channel, thumb_bytes, width, height) for a screendump file."""
    im = load_rgb(path)
    w, h = im.size
    if w == 0 or h == 0:
        raise ValueError("zero-size frame")
    # Full-resolution per-channel extrema: exact and faster than subsampling.
    maxc = max(hi for _, hi in im.getextrema())
    thumb = im.convert("L").resize(THUMB, Image.Resampling.BOX).tobytes()
    return maxc, thumb, w, h


def classify(maxc, threshold):
    return "BLACK" if maxc < threshold else "LIT"


def mean_abs_diff(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def mean_luma(thumb):
    return sum(thumb) / len(thumb)


def black_runs(recs):
    """(start_idx, last_black_idx, end_idx or None) for each run of BLACK frames."""
    runs = []
    i, n = 0, len(recs)
    while i < n:
        if recs[i]["cls"] != "BLACK":
            i += 1
            continue
        j = i
        while j + 1 < n and recs[j + 1]["cls"] == "BLACK":
            j += 1
        runs.append((i, j, j + 1 if j + 1 < n else None))
        i = j + 1
    return runs


def run_span_ms(recs, run):
    """Start, end (time of first LIT frame after the run, or last frame), duration in ms."""
    i, _, end = run
    start = recs[i]["t"]
    stop = recs[end]["t"] if end is not None else recs[-1]["t"]
    return start, stop, stop - start


def analyze(recs, cap_gaps_ms, serial_lines, min_black_ms=100):
    """Return (summary dict, long black runs list) from per-frame records."""
    if not recs:
        return {"frames": 0}, []
    first_t, last_t = recs[0]["t"], recs[-1]["t"]
    lit_idx = next((i for i, r in enumerate(recs) if r["cls"] == "LIT"), None)
    runs = black_runs(recs)
    long_runs = []
    for run in runs:
        start, stop, dur = run_span_ms(recs, run)
        if dur > min_black_ms:
            long_runs.append({"start_s": start / 1000, "end_s": stop / 1000,
                              "dur_ms": dur, "open": run[2] is None})
    if lit_idx is None:
        before_ms = last_t - first_t
        after_ms = 0
    else:
        before_ms = recs[lit_idx]["t"] - first_t
        after_ms = sum(run_span_ms(recs, r)[2] for r in runs if r[0] > lit_idx)
    sizes, changes, prev = [], [], None
    for r in recs:
        if not r["w"]:
            continue
        size = (r["w"], r["h"])
        if prev is not None and size != prev[1]:
            changes.append((r["t"] / 1000, prev[1], size))
        prev = (r["t"], size)
        sizes.append(size)
    changed = [r["t"] for r in recs if r["flag"] == "CHANGED"]
    gaps = cap_gaps_ms or []
    span_s = (last_t - first_t) / 1000 if last_t > first_t else 0
    summary = {
        "frames": len(recs),
        "frame_errors": sum(1 for r in recs if r["note"]),
        "first_frame_s": first_t / 1000,
        "last_frame_s": last_t / 1000,
        "mean_interval_ms": (sum(gaps) / len(gaps)) if gaps else 0,
        "max_interval_ms": max(gaps) if gaps else 0,
        "achieved_fps": (len(recs) - 1) / span_s if span_s > 0 else 0,
        "first_nonblack_s": recs[lit_idx]["t"] / 1000 if lit_idx is not None else None,
        "black_before_first_nonblack_s": before_ms / 1000,
        "black_after_first_nonblack_s": after_ms / 1000,
        "long_black_intervals": len(long_runs),
        "resolution_changes": changes,
        "resolutions_seen": sorted({f"{w}x{h}" for w, h in sizes}),
        "last_changed_s": (changed[-1] / 1000) if changed else None,
        "serial_lines": serial_lines,
    }
    return summary, long_runs


def pick_format(k, mode, state):
    """Format for tick k. Auto: alternate ppm/png for the probe ticks, then keep the faster."""
    if mode == "ppm" or not state["png_ok"]:
        return "ppm"
    if mode == "png":
        return "png"
    if k < PROBE_TICKS:
        return "ppm" if k % 2 == 0 else "png"
    if state["chosen"] is None:
        t = state["times"]
        if t["png"] and t["ppm"]:
            state["chosen"] = "png" if sum(t["png"]) / len(t["png"]) < sum(t["ppm"]) / len(t["ppm"]) else "ppm"
        else:
            state["chosen"] = "ppm"
    return state["chosen"]


def unique_path(frames_dir, t_ms, ext):
    t_ms = max(t_ms, 0)  # file name keeps 7 digits; negative times are noted in the record
    while True:
        p = os.path.join(frames_dir, f"t_{t_ms:07d}.{ext}")
        if not os.path.exists(p):
            return p
        t_ms += 1


def capture(a, frames_dir):
    """Screendump every 1/fps s until --seconds elapse. Returns (records, gaps_ms, format stats)."""
    qmp = Qmp(a.sock)
    qmp.connect(a.connect_timeout)
    interval = 1.0 / a.fps
    start = time.monotonic()
    k = 0
    recs, starts, notes = [], [], []
    state = {"png_ok": True, "chosen": None, "times": {"ppm": [], "png": []}}
    prev = None
    frames_dir = os.path.abspath(frames_dir)
    while True:
        target = start + k * interval
        if target - start >= a.seconds:
            break
        delay = target - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        t_ms = int(time.time() * 1000) - a.t0_ms
        early = t_ms < 0
        starts.append(time.monotonic())
        fmt = pick_format(k, a.format, state)
        rec = {"t": t_ms, "cls": "BLACK", "diff": 0.0, "luma": 0.0, "flag": "STATIC",
               "w": 0, "h": 0, "path": "", "note": "clock-before-launch" if early else ""}
        stop = False
        try:
            while True:  # retry once as ppm if png is refused
                path = unique_path(frames_dir, t_ms, fmt)
                args = {"filename": path}
                if fmt == "png":
                    args["format"] = "png"
                req = time.monotonic()
                try:
                    qmp.call("screendump", **args)
                    state["times"][fmt].append(time.monotonic() - req)
                    break
                except QmpError as e:
                    if fmt == "png" and state["png_ok"]:
                        state["png_ok"] = False
                        fmt = "ppm"
                        notes.append("png screendump refused: " + str(e))
                        continue
                    raise
            rec["path"] = path
            maxc, thumb, w, h = analyze_file(path)
            rec.update(w=w, h=h, cls=classify(maxc, a.threshold), luma=mean_luma(thumb))
            if prev is not None:
                rec["diff"] = mean_abs_diff(thumb, prev)
            rec["flag"] = "CHANGED" if rec["diff"] > CHANGE_DIFF else "STATIC"
            prev = thumb
        except QmpError as e:
            rec["note"] = "dump-error: " + str(e)
        except OSError as e:
            rec["note"] = "qmp-io: " + str(e)
            try:
                qmp.close()
                qmp.connect(5)
            except RuntimeError as e2:
                rec["note"] += "; reconnect failed: " + str(e2)
                stop = True
        except (ValueError, Image.UnidentifiedImageError) as e:
            rec["note"] = "frame-error: " + str(e)
        recs.append(rec)
        if stop:
            notes.append("capture stopped: QMP lost")
            break
        k = int((time.monotonic() - start) / interval) + 1  # skip missed ticks
    qmp.close()
    gaps = [(b - a_) * 1000 for a_, b in zip(starts, starts[1:])]
    return recs, gaps, state, notes


def write_csv(path, recs):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_ms", "class", "diff", "mean_luma", "flag", "width", "height", "note"])
        for r in recs:
            w.writerow([r["t"], r["cls"], f"{r['diff']:.3f}", f"{r['luma']:.2f}",
                        r["flag"], r["w"], r["h"], r["note"]])


def count_lines(path):
    if not os.path.exists(path):
        return 0
    n = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            n += chunk.count(b"\n")
    return n


def contact_sheet(items, out, cols=6, cell=(320, 200)):
    """items: list of (frame path or None, label)."""
    rows = max(1, math.ceil(len(items) / cols))
    cw, ch = cell
    lab = 18
    sheet = Image.new("RGB", (cols * cw, rows * (ch + lab)), (40, 40, 40))
    draw = ImageDraw.Draw(sheet)
    for i, (path, label) in enumerate(items):
        x, y = (i % cols) * cw, (i // cols) * (ch + lab)
        if path:
            try:
                im = load_rgb(path)
                im.thumbnail((cw, ch))
                sheet.paste(im, (x + (cw - im.width) // 2, y + (ch - im.height) // 2))
            except (OSError, ValueError):
                draw.text((x + 8, y + 8), "unreadable frame", fill=(255, 255, 255))
        else:
            draw.text((x + 8, y + 8), "no frame", fill=(255, 255, 255))
        draw.text((x + 4, y + ch + 3), label, fill=(255, 255, 255))
    sheet.save(out)


def write_summary(path, summary, long_runs, notes, fmt_state):
    lines = []
    lines.append(f"frames: {summary.get('frames', 0)}")
    lines.append(f"frame_errors: {summary.get('frame_errors', 0)}")
    if summary.get("frames"):
        lines.append(f"achieved_interval_mean_ms: {summary['mean_interval_ms']:.1f}")
        lines.append(f"achieved_interval_max_ms: {summary['max_interval_ms']:.1f}")
        lines.append(f"achieved_fps: {summary['achieved_fps']:.2f}")
        lines.append(f"first_frame_s: {summary['first_frame_s']:.2f}")
        lines.append(f"last_frame_s: {summary['last_frame_s']:.2f}")
        nb = summary["first_nonblack_s"]
        lines.append("first_nonblack_s: " + (f"{nb:.2f}" if nb is not None else "none"))
        lines.append(f"black_before_first_nonblack_s: {summary['black_before_first_nonblack_s']:.2f}")
        lines.append(f"black_after_first_nonblack_s: {summary['black_after_first_nonblack_s']:.2f}")
        lines.append(f"resolutions_seen: {', '.join(summary['resolutions_seen']) or 'none'}")
        ch = summary["resolution_changes"]
        lines.append(f"resolution_changes: {len(ch)}")
        for t, a_, b_ in ch:
            lines.append(f"  at {t:.2f}s: {a_[0]}x{a_[1]} -> {b_[0]}x{b_[1]}")
        lc = summary["last_changed_s"]
        lines.append("last_changed_s: " + (f"{lc:.2f}" if lc is not None else "none"))
    lines.append(f"black_intervals_over_100ms: {len(long_runs)}")
    for r in long_runs:
        tag = " (open, to end of capture)" if r["open"] else ""
        lines.append(f"  {r['start_s']:.2f}s - {r['end_s']:.2f}s  {r['dur_ms']} ms{tag}")
    lines.append(f"serial_lines: {summary.get('serial_lines', 0)}")
    times = fmt_state["times"]
    for f_ in ("ppm", "png"):
        if times[f_]:
            lines.append(f"dump_mean_ms_{f_}: {1000 * sum(times[f_]) / len(times[f_]):.1f} (n={len(times[f_])})")
    lines.append(f"format_used_after_probe: {fmt_state['chosen'] or 'fixed'}")
    for n in notes:
        lines.append("note: " + n)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_outputs(out, recs, cap_gaps, fmt_state, notes, threshold):
    serial = count_lines(os.path.join(out, "serial.log"))
    summary, long_runs = analyze(recs, cap_gaps, serial)
    write_csv(os.path.join(out, "timeline.csv"), recs)
    write_summary(os.path.join(out, "summary.txt"), summary, long_runs, notes, fmt_state)
    if not recs:
        return
    idx = sorted({round(i * (len(recs) - 1) / 23) for i in range(24)}) if len(recs) > 24 else range(len(recs))
    items = [(recs[i]["path"] or None, f"{recs[i]['t'] / 1000:.2f}s") for i in idx]
    contact_sheet(items, os.path.join(out, "contact.png"))
    black_items = []
    for run in black_runs(recs):
        start, stop, dur = run_span_ms(recs, run)
        if dur <= 100:
            continue
        s_i = run[0]
        black_items.append((recs[s_i]["path"] or None, f"{start / 1000:.2f}s start"))
        e_i = run[2] if run[2] is not None else len(recs) - 1
        tag = "end" if run[2] is not None else "end (capture stop)"
        black_items.append((recs[e_i]["path"] or None, f"{stop / 1000:.2f}s {tag}"))
    black_items = black_items[:24]
    if black_items:
        contact_sheet(black_items, os.path.join(out, "contact-black.png"))


def analyze_dir(frames_dir):
    """Rebuild records from an existing frames directory (no QMP)."""
    names = sorted(n for n in os.listdir(frames_dir) if FRAME_RE.search(n))
    recs, prev = [], None
    for n in names:
        m = FRAME_RE.search(n)
        rec = {"t": int(m.group(1)), "cls": "BLACK", "diff": 0.0, "luma": 0.0, "flag": "STATIC",
               "w": 0, "h": 0, "path": os.path.join(frames_dir, n), "note": ""}
        try:
            maxc, thumb, w, h = analyze_file(rec["path"])
            rec.update(w=w, h=h, cls=classify(maxc, ARGS.threshold), luma=mean_luma(thumb))
            if prev is not None:
                rec["diff"] = mean_abs_diff(thumb, prev)
            rec["flag"] = "CHANGED" if rec["diff"] > CHANGE_DIFF else "STATIC"
            prev = thumb
        except (OSError, ValueError) as e:
            rec["note"] = "frame-error: " + str(e)
        recs.append(rec)
    return recs


def main(argv=None):
    global ARGS
    ap = argparse.ArgumentParser(description="Capture and analyze a QEMU boot timeline.")
    ap.add_argument("--out", required=True)
    ap.add_argument("--sock", help="QMP unix socket")
    ap.add_argument("--t0-ms", type=int, default=0, help="wall clock ms of QEMU launch")
    ap.add_argument("--seconds", type=float, default=90)
    ap.add_argument("--fps", type=float, default=5)
    ap.add_argument("--format", choices=["auto", "ppm", "png"], default="auto")
    ap.add_argument("--threshold", type=int, default=8, help="BLACK when max channel < N")
    ap.add_argument("--connect-timeout", type=float, default=60)
    ap.add_argument("--analyze-only", action="store_true", help="re-analyze OUT/frames")
    ARGS = ap.parse_args(argv)
    if not (0 < ARGS.seconds <= 3600):
        ap.error("--seconds must be in (0, 3600]")
    if not (0.1 <= ARGS.fps <= 50):
        ap.error("--fps must be in [0.1, 50]")
    if not (0 <= ARGS.threshold <= 255):
        ap.error("--threshold must be in [0, 255]")
    frames_dir = os.path.join(ARGS.out, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    if ARGS.analyze_only:
        recs = analyze_dir(frames_dir)
        gaps = [b["t"] - a_["t"] for a_, b in zip(recs, recs[1:])]
        write_outputs(ARGS.out, recs, gaps, {"times": {"ppm": [], "png": []}, "chosen": "n/a"},
                      ["analyze-only run"], ARGS.threshold)
        return 0
    if not ARGS.sock:
        ap.error("--sock is required unless --analyze-only")
    recs, gaps, fmt_state, notes = [], [], {"times": {"ppm": [], "png": []}, "chosen": None}, []
    try:
        recs, gaps, fmt_state, notes = capture(ARGS, frames_dir)
    finally:
        if recs:
            write_outputs(ARGS.out, recs, gaps, fmt_state, notes, ARGS.threshold)
    print(f"done: {len(recs)} frames, summary in {os.path.join(ARGS.out, 'summary.txt')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

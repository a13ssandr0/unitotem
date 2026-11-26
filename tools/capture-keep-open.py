#!/usr/bin/env python3
"""Keeps the HDMI capture card open and records the last minutes of the screen.

The device under test only sees a display while the card is open (closing it drops the hotplug), so one ffmpeg process
holds it for good and writes MJPEG segments; segments older than --keep minutes are removed (by exact path).

    tools/capture-keep-open.py run [--device /dev/video0] [--size 1920x1080] [--fps 10] [--keep 20] [--dir DIR]
    tools/capture-keep-open.py frames SECONDS OUTDIR [--fps N]    # the last SECONDS as PNG frames named by wall-clock time
    tools/capture-keep-open.py snap FILE.png                      # the newest frame

`run` is meant for `systemd-run --user --unit=capture-keep-open --property=Restart=always`.
"""
import argparse
import datetime
import os
import re
import signal
import subprocess
import sys
import time

DEFAULT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "work", "capture")
SEG = re.compile(r"^seg-(\d{8}-\d{6})\.mkv$")


def seg_time(name):
    m = SEG.match(name)
    return datetime.datetime.strptime(m.group(1), "%Y%m%d-%H%M%S") if m else None


def segments(directory):
    out = []
    for name in os.listdir(directory):
        t = seg_time(name)
        if t:
            out.append((t, os.path.join(directory, name)))
    return sorted(out)


def run(a):
    os.makedirs(a.dir, exist_ok=True)
    cmd = ["ffmpeg", "-nostdin", "-loglevel", "warning", "-f", "v4l2", "-video_size", a.size, "-framerate", "30",
           "-i", a.device, "-an", "-vf", f"fps={a.fps}", "-c:v", "mjpeg", "-q:v", "4",
           "-f", "segment", "-segment_time", "20", "-strftime", "1", "-reset_timestamps", "1",
           os.path.join(a.dir, "seg-%Y%m%d-%H%M%S.mkv")]
    proc = subprocess.Popen(cmd)
    signal.signal(signal.SIGTERM, lambda *_: (proc.terminate(), sys.exit(0)))
    limit = datetime.timedelta(minutes=a.keep)
    while proc.poll() is None:
        time.sleep(15)
        now = datetime.datetime.now()
        for t, path in segments(a.dir)[:-2]:        # never the newest two: one is still being written
            if now - t > limit:
                os.remove(path)
    sys.exit(proc.returncode)


def frames(a):
    os.makedirs(a.outdir, exist_ok=True)
    start = datetime.datetime.now() - datetime.timedelta(seconds=a.seconds)
    for t, path in segments(a.dir):
        if t + datetime.timedelta(seconds=25) < start:
            continue
        base = t.strftime("%H%M%S")
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", path, "-vf", f"fps={a.fps}",
                        os.path.join(a.outdir, f"{base}-%03d.png")], check=False)


def snap(a):
    segs = segments(a.dir)
    if len(segs) < 2:
        sys.exit("no segment yet")
    path = segs[-2][1]                                # the last finished segment
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-sseof", "-1", "-i", path, "-frames:v", "1", a.file],
                   check=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dir", default=DEFAULT_DIR)
    sp = p.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("run")
    r.add_argument("--device", default="/dev/video0")
    r.add_argument("--size", default="1920x1080")
    r.add_argument("--fps", type=int, default=10)
    r.add_argument("--keep", type=int, default=20)
    f = sp.add_parser("frames")
    f.add_argument("seconds", type=int)
    f.add_argument("outdir")
    f.add_argument("--fps", type=int, default=2)
    s = sp.add_parser("snap")
    s.add_argument("file")
    a = p.parse_args()
    {"run": run, "frames": frames, "snap": snap}[a.cmd](a)


if __name__ == "__main__":
    main()

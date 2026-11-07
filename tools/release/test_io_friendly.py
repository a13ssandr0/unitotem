#!/usr/bin/env python3
"""Host-side test of the I/O settings unitotem-update applies while it writes an image (class io_friendly): on SD/USB disks bfq
and a small dirty-page cap, restored afterwards (ratios last), a killed run undone by the next, NVMe left alone, a failure never fatal.

  python3 tools/release/test_io_friendly.py
"""
import importlib.machinery, importlib.util, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "unitotem/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)


def rd(p): return open(p).read().strip()
def wr(p, v): os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "w").write(v)


def tree(td, disk, part, sched="none [mq-deadline] kyber bfq"):
    sysd = os.path.join(td, "sys"); vmd = os.path.join(td, "vm"); run = os.path.join(td, "run")
    os.makedirs(run, exist_ok=True)
    wr(f"{sysd}/block/{disk}/queue/scheduler", sched)
    os.makedirs(f"{sysd}/block/{disk}/{part}", exist_ok=True)
    wr(f"{sysd}/block/{disk}/{part}/partition", "2")
    os.makedirs(f"{sysd}/class/block", exist_ok=True)
    os.symlink(f"{sysd}/block/{disk}/{part}", f"{sysd}/class/block/{part}")
    for k, v in (("dirty_background_bytes", "0"), ("dirty_bytes", "0"), ("dirty_background_ratio", "10"), ("dirty_ratio", "20")):
        wr(f"{vmd}/{k}", v)
    dev = os.path.join(td, "dev", part); os.makedirs(os.path.dirname(dev), exist_ok=True); os.symlink(f"{sysd}/block/{disk}/{part}", dev)
    return dict(uu.CONF_DEFAULTS, UPDATE_SYS_DIR=sysd, UPDATE_VM_DIR=vmd, UPDATE_RUN_DIR=run, UPDATE_STATE_DIR=os.path.join(td, "state")), dev, sysd, vmd, run


def kernel_zeroes_ratio(vmd):
    pass                                   # kept for the call sites: FakeKernel applies the kernel's rules on every write


class FakeKernel(uu.io_friendly):
    """The /proc/sys/vm rules the real kernel (6.18, seen on a Raspberry Pi 4) applies: a limit is a ratio or a byte value,
    writing one form zeroes the other, and a byte value cannot be set to 0 while its ratio is 0 (EINVAL)."""
    def _write(self, path, value):
        d, name, v = os.path.dirname(path), os.path.basename(path), str(value)
        if os.path.basename(d) != "vm":
            return super()._write(path, value)
        if name.endswith("_bytes"):
            ratio = f"{d}/{name[:-6]}_ratio"
            if v == "0" and rd(ratio) == "0": raise OSError(22, "Invalid argument")
            wr(path, v)
            if v != "0": wr(ratio, "0")
        elif name.endswith("_ratio"):
            wr(path, v)
            if v != "0": wr(f"{d}/{name[:-6]}_bytes", "0")
        else:
            wr(path, v)


with tempfile.TemporaryDirectory() as td:
    conf, dev, sysd, vmd, run = tree(td, "mmcblk0", "mmcblk0p2")
    os.makedirs(conf["UPDATE_STATE_DIR"], exist_ok=True)
    f = FakeKernel(conf, dev); f.apply(); kernel_zeroes_ratio(vmd)
    check("SD: scheduler set to bfq", rd(f"{sysd}/block/mmcblk0/queue/scheduler") == "bfq")
    check("SD: dirty bytes capped", rd(f"{vmd}/dirty_bytes") == str(64 << 20) and rd(f"{vmd}/dirty_background_bytes") == str(16 << 20))
    check("SD: previous values kept in the run dir", os.path.exists(os.path.join(run, "unitotem-update-io.json")))
    f.restore(); kernel_zeroes_ratio(vmd)
    check("restore: scheduler back to mq-deadline", rd(f"{sysd}/block/mmcblk0/queue/scheduler") == "mq-deadline")
    check("restore: bytes back to 0", rd(f"{vmd}/dirty_bytes") == "0" and rd(f"{vmd}/dirty_background_bytes") == "0")
    check("restore: ratios back (written last)", rd(f"{vmd}/dirty_ratio") == "20" and rd(f"{vmd}/dirty_background_ratio") == "10")
    check("restore: state file removed", not os.path.exists(os.path.join(run, "unitotem-update-io.json")))
    f.restore()
    check("restore twice is harmless", rd(f"{sysd}/block/mmcblk0/queue/scheduler") == "mq-deadline")

with tempfile.TemporaryDirectory() as td:
    conf, dev, sysd, vmd, run = tree(td, "mmcblk0", "mmcblk0p2")
    f = FakeKernel(conf, dev); f.apply(); kernel_zeroes_ratio(vmd)          # this run is "killed": no restore
    g = FakeKernel(conf, dev); g.apply(); kernel_zeroes_ratio(vmd)          # the next run undoes it first, then applies its own
    g.restore(); kernel_zeroes_ratio(vmd)
    check("killed run: the next run restores the original values", rd(f"{sysd}/block/mmcblk0/queue/scheduler") == "mq-deadline"
          and rd(f"{vmd}/dirty_bytes") == "0" and rd(f"{vmd}/dirty_ratio") == "20")

with tempfile.TemporaryDirectory() as td:
    conf, dev, sysd, vmd, run = tree(td, "nvme0n1", "nvme0n1p2", sched="[none] mq-deadline kyber bfq")
    f = FakeKernel(conf, dev); f.apply()
    check("NVMe: untouched", rd(f"{sysd}/block/nvme0n1/queue/scheduler") == "[none] mq-deadline kyber bfq" and rd(f"{vmd}/dirty_bytes") == "0")
    check("NVMe: no state file", not os.path.exists(os.path.join(run, "unitotem-update-io.json")))
    f.restore()

with tempfile.TemporaryDirectory() as td:
    conf, dev, sysd, vmd, run = tree(td, "sda", "sda2", sched="none [mq-deadline] kyber")          # no bfq in the kernel
    f = FakeKernel(conf, dev); f.apply(); kernel_zeroes_ratio(vmd)
    check("no bfq: scheduler left, dirty cap still applied", rd(f"{sysd}/block/sda/queue/scheduler") == "none [mq-deadline] kyber"
          and rd(f"{vmd}/dirty_bytes") == str(64 << 20))
    f.restore(); kernel_zeroes_ratio(vmd)
    check("no bfq: restore", rd(f"{vmd}/dirty_bytes") == "0" and rd(f"{vmd}/dirty_ratio") == "20" and rd(f"{sysd}/block/sda/queue/scheduler") == "none [mq-deadline] kyber")

with tempfile.TemporaryDirectory() as td:
    conf, dev, sysd, vmd, run = tree(td, "mmcblk0", "mmcblk0p2")
    os.unlink(f"{vmd}/dirty_bytes")
    f = FakeKernel(conf, dev)
    try:
        f.apply(); f.restore(); good = True
    except Exception as e:
        good = False; print(e)
    check("a failure (missing sysctl file) never raises", good)

with tempfile.TemporaryDirectory() as td:
    conf, dev, sysd, vmd, run = tree(td, "mmcblk0", "mmcblk0p2")
    for k, v in (("dirty_background_bytes", "1048576"), ("dirty_bytes", "8388608"), ("dirty_background_ratio", "0"), ("dirty_ratio", "0")):
        wr(f"{vmd}/{k}", v)
    f = FakeKernel(conf, dev); f.apply(); f.restore()
    check("original byte limits are written back as bytes", rd(f"{vmd}/dirty_bytes") == "8388608" and rd(f"{vmd}/dirty_background_bytes") == "1048576"
          and rd(f"{vmd}/dirty_ratio") == "0")

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

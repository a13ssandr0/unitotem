#!/usr/bin/env python3
"""Host-side test of the boot health gate of unitotem-update (boot-ok): the boot counter on the boot FAT, the
reboot of an unhealthy boot, the trial path, the status fields and the slot device lookup. No device, no root,
no real reboot: the boot FAT, ESP, state and run directories are temporary, UPDATE_REBOOT_CMD records the reboot,
the health check is a stub and the clock is a fake one (the 180 s health wait runs instantly).

  python3 tools/release/test_boot_guard.py
"""
import argparse, importlib.machinery, importlib.util, os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0
real_time = time


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def wait_file(path, timeout=5.0):
    """Bounded wait for the reboot stub (Popen) to write its record."""
    end = real_time.monotonic() + timeout
    while real_time.monotonic() < end:
        if os.path.exists(path): return True
        real_time.sleep(0.05)
    return os.path.exists(path)


class FakeTime:
    """Monotonic clock and sleep of unitotem-update advance a fake clock; everything else is the real time module."""
    def __init__(self): self.t = 0.0
    def __getattr__(self, name): return getattr(real_time, name)
    def monotonic(self): return self.t
    def sleep(self, s): self.t += s


loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "unitotem/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)
uu.time = FakeTime()

SRC_PATH = os.path.join(ROOT, "unitotem/files/unitotem-update")
src_text = open(SRC_PATH).read()

with tempfile.TemporaryDirectory() as td:
    bf = os.path.join(td, "firmware"); os.makedirs(bf)
    esp = os.path.join(td, "esp"); os.makedirs(esp)           # boot FAT of the amd64 layout; nothing mounted here
    open(os.path.join(bf, "config.txt"), "w").write("arm_64bit=1\n[all]\nos_prefix=slota/\nkernel=kernel8.img\n")
    cmdline = os.path.join(td, "cmdline")
    state = os.path.join(td, "state"); run = os.path.join(td, "run"); os.makedirs(run)
    reboots = os.path.join(td, "reboots")
    verf = os.path.join(td, "version"); open(verf, "w").write("2026.11.09\n")
    ovl = os.path.join(td, "overlay.status")
    dt = os.path.join(td, "dt"); os.makedirs(dt)

    def write_cmdline(text): open(cmdline, "w").write(text + "\n")

    def conf_for(**kw):
        base = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="rpi", UPDATE_BOOTFS=bf, UPDATE_ESP_MOUNT=esp,
                    UPDATE_DT_BOOTLOADER=dt, UPDATE_STATE_DIR=state, UPDATE_RUN_DIR=run, UPDATE_CMDLINE=cmdline,
                    UPDATE_DATA=os.path.join(td, "data"), UPDATE_ETC_CURRENT=os.path.join(td, "etc"),
                    UPDATE_VERSION_FILE=verf, UPDATE_OVERLAY_STATUS=ovl,
                    UPDATE_RECOVERY_DIR=os.path.join(td, "no-recovery"), UPDATE_ESP_GRUBCFG=os.path.join(td, "no-grub.cfg"),
                    UPDATE_GRUBENV=os.path.join(td, "no-grubenv"), UPDATE_HEALTH_CA=os.path.join(td, "no-ca.pem"),
                    UPDATE_HEALTH_URL="https://127.0.0.1:1/health", UPDATE_HEALTH_TIMEOUT="180",
                    UPDATE_AUTOREPAIR="0", UPDATE_REBOOT_CMD=f"echo trial=$UNITOTEM_REBOOT_TRIAL >> {reboots}")
        base.update(kw)
        return base

    health = {"ok": True, "calls": 0}

    def fake_health(conf):
        health["calls"] += 1
        return health["ok"]

    uu.health_ok = fake_health
    cfile = os.path.join(bf, uu.BOOTCOUNT)

    def set_count(text):
        with open(cfile, "w") as f: f.write(text)

    def reboot_records():
        return open(reboots).read().splitlines() if os.path.exists(reboots) else []

    def fresh_boot(cmd_line, count=None):
        """Clean fixture state for one boot: no reboot record, no state, the given counter (None = no file)."""
        for p in (reboots, cfile, ovl, os.path.join(state, "pending.json"), os.path.join(state, "slots.json")):
            if os.path.exists(p): os.unlink(p)
        os.makedirs(state, exist_ok=True)
        write_cmdline(cmd_line)
        if count is not None: set_count(count)
        health["calls"] = 0

    BOOT_A = "root=LABEL=ROOT_A unitotem.slot=a"
    NOSLOT = "root=LABEL=ROOT"

    # 1. healthy plain boot: counter cleared in place, no reboot
    fresh_boot(BOOT_A, "3\n")
    ino = os.stat(cfile).st_ino
    c = conf_for()
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    check("healthy boot: rc 0", rc == 0, str((rc, out)))
    check("healthy boot: counter reads 0", open(cfile).read() == "0\n")
    check("healthy boot: file inode and size unchanged", os.stat(cfile).st_ino == ino and os.path.getsize(cfile) == 2)
    check("healthy boot: no reboot", reboot_records() == [])
    check("healthy boot: health checked once", health["calls"] == 1)

    # 2. unhealthy boot with counter 2: reboot, rc 2, the slot is not confirmed
    fresh_boot(BOOT_A, "2\n"); health["ok"] = False
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    check("unhealthy counter 2: reboot requested", wait_file(reboots) and reboot_records() == ["trial=0"], str(reboot_records()))
    check("unhealthy counter 2: rc 2, error_code health-timeout", rc == 2 and out.get("error_code") == "health-timeout", str((rc, out)))
    check("unhealthy counter 2: slot not confirmed (no slots.json written)", not os.path.exists(os.path.join(state, "slots.json")))
    check("unhealthy counter 2: counter kept at 2", open(cfile).read() == "2\n")
    check("unhealthy: waited the whole health timeout", health["calls"] > 1)
    health["ok"] = True

    # 3. unhealthy without a counter file: no reboot (nothing would count)
    fresh_boot(BOOT_A, None); health["ok"] = False
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    real_time.sleep(0.3)
    check("unhealthy, no counter file: no reboot", reboot_records() == [])
    check("unhealthy, no counter file: rc 2", rc == 2 and out.get("error_code") == "health-timeout")
    health["ok"] = True

    # 3b. unhealthy with counter 0 (the initramfs counts before the boot, so 0 means it did not count): no reboot
    fresh_boot(BOOT_A, "0\n"); health["ok"] = False
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    real_time.sleep(0.3)
    check("unhealthy, counter 0: no reboot", reboot_records() == [])
    health["ok"] = True

    # 4. counter already 0 on a healthy boot: the FAT is not written (mtime unchanged)
    fresh_boot(BOOT_A, "0\n")
    os.utime(cfile, ns=(1_000_000_000, 1_000_000_000))
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    check("counter 0: healthy boot writes nothing (mtime unchanged)", os.stat(cfile).st_mtime_ns == 1_000_000_000)

    # 5. maintenance boot: the gate is skipped even when unhealthy with a counter set
    fresh_boot(BOOT_A + " unitotem.maintenance=1", "2\n"); health["ok"] = False
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    real_time.sleep(0.3)
    check("maintenance: no health check, no reboot", health["calls"] == 0 and reboot_records() == [])
    check("maintenance: rc 0 and counter untouched", rc == 0 and open(cfile).read() == "2\n", str((rc, out)))
    health["ok"] = True

    # 6. trial boot of the pending slot: confirmed and the counter cleared
    fresh_boot(BOOT_A, "2\n")
    st = {"a": {"version": "1", "valid": True, "confirmed": True}, "b": {"version": "2", "valid": True, "prepared": True}}
    uu.write_state(c, "slots.json", st)
    uu.write_state(c, "pending.json", {"slot": "a", "from": "b", "from_version": "1", "version": "2"})
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    check("trial boot: confirmed", rc == 0 and out.get("confirmed") is True, str((rc, out)))
    check("trial boot: counter cleared", open(cfile).read() == "0\n")
    check("trial boot: no reboot", reboot_records() == [])
    check("trial boot: pending removed", not os.path.exists(os.path.join(state, "pending.json")))

    # 7. non-A/B system (no unitotem.slot=): the gate runs; unhealthy with counter 1 reboots
    fresh_boot(NOSLOT, "1\n"); health["ok"] = False
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    check("non-A/B unhealthy counter 1: reboot", wait_file(reboots) and rc == 2, str((rc, out)))
    health["ok"] = True
    fresh_boot(NOSLOT, "1\n")
    rc, out = uu.cmd_boot_ok(argparse.Namespace(), c)
    check("non-A/B healthy: counter cleared, ab False", open(cfile).read() == "0\n" and out == {"ab": False}, str(out))

    # 8. counter garbage: reads 0, a healthy boot rewrites it to 0
    fresh_boot(BOOT_A, "x?\n")
    check("garbage counter reads 0", uu.bootcount_read(c) == 0)
    uu.cmd_boot_ok(argparse.Namespace(), c)
    check("garbage counter cleared on a healthy boot", open(cfile).read() == "0\n")
    fresh_boot(BOOT_A, "7\n")
    check("counter 7 reads 7", uu.bootcount_read(c) == 7)

    # 9. counter on the ESP (amd64 layout) is found and cleared as well
    for p in (cfile,):
        if os.path.exists(p): os.unlink(p)
    ecount = os.path.join(esp, uu.BOOTCOUNT)
    with open(ecount, "w") as f: f.write("1\n")
    fresh_boot(BOOT_A)
    c_esp = conf_for(UPDATE_BOOTFS=os.path.join(td, "no-bootfs"))
    os.makedirs(c_esp["UPDATE_BOOTFS"], exist_ok=True)
    uu.cmd_boot_ok(argparse.Namespace(), c_esp)
    check("ESP counter cleared", open(ecount).read() == "0\n")
    os.unlink(ecount)

    # 10. clear failure is recorded, never raised: the boot FAT cannot be remounted read-write (simulated)
    fresh_boot(BOOT_A, "2\n")
    real_rw = uu.bootfs_rw

    class ReadOnlyFat:
        def __init__(self, path): self.path = path
        def __enter__(self): raise uu.Fail("bootfs-rw", "simulated read-only boot FAT")
        def __exit__(self, *e): return False

    uu.bootfs_rw = ReadOnlyFat
    try:
        uu.bootcount_clear(c); raised = False
    except Exception:
        raised = True
    finally:
        uu.bootfs_rw = real_rw
    check("clear failure never raised", not raised)
    check("clear failure: counter unchanged", open(cfile).read() == "2\n")
    ev = os.path.join(state, "events.log")
    check("clear failure logged in events.log", os.path.exists(ev) and "boot counter clear failed" in open(ev).read())

    # 11. status: new fields on A/B and non-A/B, overlay line, boot attempts
    write_cmdline(BOOT_A); fresh_boot(BOOT_A, "2\n")
    open(ovl, "w").write("volatile: DATA unavailable\nsecond line\n")
    rc, out = uu.cmd_status(argparse.Namespace(), c)
    check("status: overlay is the first line", out.get("overlay") == "volatile: DATA unavailable", str(out.get("overlay")))
    check("status: volatile true", out.get("volatile") is True)
    check("status: boot_attempts 2", out.get("boot_attempts") == 2, str(out.get("boot_attempts")))
    check("status: existing fields kept", out.get("ab") is True and out.get("slot") == "a" and "last_result" in out and "layout" in out)
    os.unlink(ovl); os.unlink(cfile)
    rc, out = uu.cmd_status(argparse.Namespace(), c)
    check("status: no overlay file -> overlay null, volatile false", out.get("overlay") is None and out.get("volatile") is False)
    check("status: no counter file -> boot_attempts null", out.get("boot_attempts") is None)
    open(ovl, "w").write("ok\n")
    rc, out = uu.cmd_status(argparse.Namespace(), c)
    check("status: ok overlay not volatile", out.get("overlay") == "ok" and out.get("volatile") is False)
    fresh_boot(NOSLOT, "1\n")                 # also removes the overlay file: a non-A/B boot without one
    rc, out = uu.cmd_status(argparse.Namespace(), c)
    check("status on a non-A/B system: rc 0, fields present", rc == 0 and out.get("ab") is False and out.get("boot_attempts") == 1
          and "overlay" in out and "volatile" in out, str(out))

    # 12. slot_dev: PARTLABEL first, then the filesystem label, through a blkid stub on PATH
    binp = os.path.join(td, "bin"); os.makedirs(binp)
    stub = os.path.join(binp, "blkid")
    with open(stub, "w") as f:
        f.write('#!/bin/sh\n'
                'case "$*" in\n'
                '  *"-t PARTLABEL=ROOT_A"*) echo /dev/pl-a ;;\n'
                '  *"-L ROOT_A"*) echo /dev/lab-a ;;\n'
                '  *"-L ROOT_B"*) echo /dev/lab-b ;;\n'
                'esac\n'
                'exit 0\n')
    os.chmod(stub, 0o755)
    old_path = os.environ.get("PATH", "")
    os.environ["PATH"] = binp + os.pathsep + old_path
    try:
        check("slot_dev: PARTLABEL wins over the label", uu.slot_dev("a") == "/dev/pl-a")
        check("slot_dev: no PARTLABEL -> filesystem label (MBR)", uu.slot_dev("b") == "/dev/lab-b")
    finally:
        os.environ["PATH"] = old_path
    check("slot_dev: no PARTLABEL=ROOT_ lookup outside the helper",
          src_text.count('"PARTLABEL=') == 1 and 'f"PARTLABEL={label(slot)}"' in src_text, "")

    # 13. boot-ok script: runs on every boot (static)
    bo = open(os.path.join(ROOT, "unitotem/files/unitotem-boot-ok")).read()
    check("boot-ok script: no unitotem.slot= gate", "unitotem.slot=" not in bo)
    check("boot-ok script: calls boot-ok with || true", "--json boot-ok || true" in bo)

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

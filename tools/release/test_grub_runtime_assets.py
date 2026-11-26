#!/usr/bin/env python3
"""Test of the runtime boot pictures of unitotem-update: ensure_boot_pictures (the image's generator kit run for the recorded
display mode), png_ok, mount_rw, sync_esp_grubcfg's first-boot order, and the eDP choice of drm_mode. Every path is inside a
temporary directory. The generator is the real unitotem/grub-boot-assets.py with the repo theme and font; grub-editenv is
the real one on a temporary grubenv; mount and sync are recorded, never run. systemd-run is recorded by a stub of run_out,
never started.

  python3 tools/release/test_grub_runtime_assets.py
"""
import argparse, fcntl, importlib.machinery, importlib.util, os, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "unitotem/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)

GEN_SRC = os.path.join(ROOT, "unitotem/grub-boot-assets.py")
THEME_SRC = os.path.join(ROOT, "unitotem-manager/plymouth/unitotem")
FONT_SRC = os.path.join(ROOT, "unitotem-manager/manager/plugins/unitotem_viewer/static/NotoSans.ttf")
TIERS = (1280, 1920, 2560, 3840)
VERSION = "2026.12~dev1"
HAVE_EDITENV = shutil.which("grub-editenv") is not None
cfg = lambda lvl: (f"# unitotem-grub-level: {lvl}\n" if lvl else "") + "menuentry 'A' --id slot-a {}\nmenuentry 'B' --id slot-b {}\nmenuentry 'O' --id ota-recovery {}\n"
HOSTILE = ["0x0", "99999x99999", "1920x1080;rm", "1920x1080\n", "-1x5", " 1920x1080", "١٩٢٠x1080",
           "8193x200", "1x1", "8192x8192"]
real_run = subprocess.run
real_run_out = uu.run_out


def png_size(data):
    return struct.unpack(">II", data[16:24]) if data[:8] == uu.PNG_SIG and len(data) >= 24 else None


def read(path):
    return open(path, "rb").read()


with tempfile.TemporaryDirectory() as td:
    real = os.path.realpath(td)
    tool = os.path.join(real, "tool"); theme = os.path.join(tool, "theme")
    os.makedirs(theme)
    shutil.copy(GEN_SRC, os.path.join(tool, "grub-boot-assets.py"))
    for t in TIERS:
        for k in ("wordmark", "spinner"):
            shutil.copy(os.path.join(THEME_SRC, f"{k}-{t}.png"), os.path.join(theme, f"{k}-{t}.png"))
    shutil.copy(FONT_SRC, os.path.join(tool, "NotoSans.ttf"))
    script = os.path.join(tool, "grub-boot-assets.py")
    font = os.path.join(tool, "NotoSans.ttf")
    orig_script = read(script)

    esp = os.path.join(real, "esp")
    logo_dir = os.path.join(esp, "unitotem-grub", "grub", "logo")
    os.makedirs(logo_dir)
    genv = os.path.join(esp, "unitotem-grub", "grub", "grubenv")
    target = os.path.join(esp, "unitotem-grub", "grub", "grub.cfg")
    shipped = os.path.join(real, "esp-grub.cfg")
    rootfs = os.path.join(real, "root")
    slotdir = os.path.join(rootfs, "usr", "share", "unitotem", "grub-boot")
    os.makedirs(slotdir)
    mounts = os.path.join(real, "mounts")
    cmdline = os.path.join(real, "cmdline")
    version = os.path.join(real, "release-version")
    run = os.path.join(real, "run"); os.makedirs(run)
    state = os.path.join(real, "state"); os.makedirs(state)
    drm = os.path.join(real, "drm"); os.makedirs(drm)
    empty = os.path.join(real, "empty-drm"); os.makedirs(empty)
    open(cmdline, "w").write("BOOT_IMAGE=/vmlinuz unitotem.slot=a quiet\n")
    open(version, "w").write(VERSION + "\n")
    open(mounts, "w").write(f"tmpfs {real}/other tmpfs rw 0 0\nrootfs {rootfs} ext4 ro,relatime 0 0\n")
    conf = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="grub", UPDATE_ESP_MOUNT=esp, UPDATE_GRUBENV=genv,
                UPDATE_BOOT_TOOL=tool, UPDATE_BOOT_TOOL_TIMEOUT="60", UPDATE_SLOT_PICTURES=slotdir,
                UPDATE_MOUNTS=mounts, UPDATE_CMDLINE=cmdline, UPDATE_VERSION_FILE=version, UPDATE_RUN_DIR=run,
                UPDATE_STATE_DIR=state, UPDATE_DRM_DIR=empty, UPDATE_ESP_GRUBCFG=shipped,
                UPDATE_ESP_ASSETS=os.path.join(real, "assets"))

    # --- recorded mount and sync calls; every other subprocess call runs for real
    calls = []
    mount_rc = [0]

    def fake_run(cmd, *a, **k):
        if cmd and cmd[0] in ("mount", "sync"):
            calls.append(list(cmd))
            return subprocess.CompletedProcess(cmd, mount_rc[0] if cmd[0] == "mount" else 0, "", "cannot remount")
        return real_run(cmd, *a, **k)

    gen_calls = []
    real_gen = uu._generate_picture

    def spy_gen(*a, **k):
        gen_calls.append(a[1])
        return real_gen(*a, **k)

    subprocess.run = fake_run
    uu._generate_picture = spy_gen
    try:
        # --- drm_mode: eDP first, otherwise the first connected display in sorted order
        n = [0]

        def displays(*items):
            n[0] += 1
            base = os.path.join(real, f"drm-{n[0]}"); os.makedirs(base)
            for name, status, modes in items:
                d = os.path.join(base, name); os.makedirs(d)
                open(os.path.join(d, "status"), "w").write(status + "\n")
                if modes is not None: open(os.path.join(d, "modes"), "w").write(modes)
            return dict(conf, UPDATE_DRM_DIR=base)

        c = displays(("card0-eDP-1", "connected", "1920x1200\n"), ("card0-DP-2", "connected", "3840x2160\n"))
        check("drm_mode: eDP is preferred over a connected DP", uu.drm_mode(c) == "1920x1200", uu.drm_mode(c))
        c = displays(("card1-eDP-1", "connected", "1920x1200\n"), ("card0-DP-2", "connected", "3840x2160\n"))
        check("drm_mode: eDP wins whatever its card number", uu.drm_mode(c) == "1920x1200", uu.drm_mode(c))
        c = displays(("card0-eDP-1", "disconnected", "1920x1200\n"), ("card0-DP-2", "connected", "3840x2160\n"))
        check("drm_mode: a disconnected eDP is not chosen", uu.drm_mode(c) == "3840x2160", uu.drm_mode(c))
        c = displays(("card0-DP-2", "connected", "3840x2160\n"), ("card0-HDMI-A-2", "connected", "1920x1080\n"))
        check("drm_mode: no eDP, first connected in sorted order (DP-2 before HDMI-A-2)", uu.drm_mode(c) == "3840x2160",
              uu.drm_mode(c))
        c = displays(("card0-HDMI-A-1", "connected", "1280x720\n"), ("card0-DP-1", "connected", "1600x900\n"))
        check("drm_mode: sorted order, not connection order (DP-1 before HDMI-A-1)", uu.drm_mode(c) == "1600x900", uu.drm_mode(c))
        c = displays(("card0-eDP-1", "connected", None), ("card0-DP-2", "connected", "3840x2160\n"))
        check("drm_mode: an eDP without modes falls back to the next connected display", uu.drm_mode(c) == "3840x2160",
              uu.drm_mode(c))
        c = displays(("card0-eDP-1", "connected", "garbage\n"), ("card0-DP-2", "connected", "3840x2160\n"))
        check("drm_mode: a garbage eDP mode gives None (as any first connected display)", uu.drm_mode(c) is None)

        # --- boot_mode and png_ok on their own
        check("boot_mode: accepts 1920x1080 and the limit 7680x4320", uu.boot_mode("1920x1080") == (1920, 1080)
              and uu.boot_mode("7680x4320") == (7680, 4320))
        check("boot_mode: rejects 8192x200 (width over the 7680 bound)", uu.boot_mode("8192x200") is None)
        check("boot_mode: rejects 8192x8192 (area over the limit)", uu.boot_mode("8192x8192") is None)
        check("boot_mode: rejects a non-str value", uu.boot_mode(None) is None)
        check("png_ok: a non-PNG is refused", not uu.png_ok(b"not a png", 1, 1))

        if not HAVE_EDITENV:
            print("SKIP: grub-editenv missing: runtime picture checks not run")
        else:
            subprocess.run(["grub-editenv", genv, "create"], check=True)
            open(target, "w").write(cfg(6)); open(shipped, "w").write(cfg(6))

            def set_mode(mode):
                real_run(["grub-editenv", genv, "set", f"unitotem_gfx={mode}"], check=True)

            def logo_of(mode):
                return os.path.join(logo_dir, mode + ".png")

            def slot_of(mode, slot="a"):
                return os.path.join(slotdir, f"boot-{slot}-{mode}.png")

            def drop(*paths):
                for p in paths:
                    if os.path.exists(p): os.unlink(p)

            def direct(mode, kind, slot="a"):
                """The generator's own output for MODE, run directly into a fresh directory."""
                out = os.path.join(real, f"direct-{kind}-{mode}-{slot}")
                os.makedirs(out, exist_ok=True)
                if kind == "logo":
                    args = ["logo", "--theme", theme, "--out", out, "--modes", mode]
                    name = f"{mode}.png"
                else:
                    args = ["slot", "--theme", theme, "--font", font, "--version", VERSION, "--out", out,
                            "--modes", mode, "--slots", slot]
                    name = f"boot-{slot}-{mode}.png"
                real_run([sys.executable, "-I", script] + args, check=True, capture_output=True)
                return os.path.join(out, name)

            def tree_files():
                found = set()
                for dp, dn, fn in os.walk(real):
                    if os.path.realpath(dp).startswith(state):
                        continue
                    for f in fn:
                        found.add(os.path.join(dp, f))
                return found

            def event_text():
                p = os.path.join(state, "events.log")
                return open(p).read() if os.path.exists(p) else ""

            # --- mode in the table, pictures present: nothing generated, nothing written
            set_mode("1920x1080")
            real_run([sys.executable, "-I", script, "logo", "--theme", theme, "--out", logo_dir, "--modes", "1920x1080"],
                     check=True, capture_output=True)
            real_run([sys.executable, "-I", script, "slot", "--theme", theme, "--font", font, "--version", VERSION,
                      "--out", slotdir, "--modes", "1920x1080", "--slots", "a"], check=True, capture_output=True)
            before = {p: os.stat(p).st_mtime_ns for p in (logo_of("1920x1080"), slot_of("1920x1080"))}
            gen_calls.clear(); calls.clear()
            check("table mode with pictures present: nothing returned", uu.ensure_boot_pictures(conf) == [])
            check("table mode with pictures present: no generator run, no mount call", gen_calls == [] and calls == [], (gen_calls, calls))
            check("table mode with pictures present: mtimes unchanged",
                  {p: os.stat(p).st_mtime_ns for p in before} == before)

            # --- mode outside the table: ESP logo and running slot picture generated, exact size and content
            set_mode("1600x1000")
            gen_calls.clear(); calls.clear()
            written = uu.ensure_boot_pictures(conf)
            check("1600x1000: both pictures written", sorted(written) == sorted([logo_of("1600x1000"), slot_of("1600x1000")]), written)
            check("1600x1000: ESP logo is 1600x1000", os.path.isfile(logo_of("1600x1000")) and png_size(read(logo_of("1600x1000"))) == (1600, 1000))
            check("1600x1000: slot picture is 1600x1000", os.path.isfile(slot_of("1600x1000")) and png_size(read(slot_of("1600x1000"))) == (1600, 1000))
            check("1600x1000: logo equals the generator's own output for that mode",
                  read(logo_of("1600x1000")) == read(direct("1600x1000", "logo")))
            check("1600x1000: slot picture equals the generator's own output for that mode",
                  read(slot_of("1600x1000")) == read(direct("1600x1000", "slot")))
            check("1600x1000: no temporary or .new file left", not any(p.endswith(".new") or "/.tmp-" in p for p in tree_files()))
            check("1600x1000: the run directory is cleaned up", os.listdir(run) == [], os.listdir(run))

            # --- idempotent: a second call writes nothing
            t1 = {p: os.stat(p).st_mtime_ns for p in written}
            check("second call: nothing written", uu.ensure_boot_pictures(conf) == [])
            check("second call: mtimes unchanged", {p: os.stat(p).st_mtime_ns for p in written} == t1)

            # --- damaged ESP logo of a table mode: truncated file is regenerated, the slot picture is left alone
            set_mode("1280x720")
            real_run([sys.executable, "-I", script, "slot", "--theme", theme, "--font", font, "--version", VERSION,
                      "--out", slotdir, "--modes", "1280x720", "--slots", "a"], check=True, capture_output=True)
            real_run([sys.executable, "-I", script, "logo", "--theme", theme, "--out", logo_dir, "--modes", "1280x720"],
                     check=True, capture_output=True)
            good = read(logo_of("1280x720"))
            open(logo_of("1280x720"), "wb").write(good[:len(good) // 2])
            slot_t = os.stat(slot_of("1280x720")).st_mtime_ns
            written = uu.ensure_boot_pictures(conf)
            check("truncated logo: regenerated to the full picture", written == [logo_of("1280x720")]
                  and read(logo_of("1280x720")) == good, written)
            check("truncated logo: the intact slot picture is not rewritten", os.stat(slot_of("1280x720")).st_mtime_ns == slot_t)

            # --- logo missing of a table mode
            drop(logo_of("1280x720"))
            written = uu.ensure_boot_pictures(conf)
            check("missing logo of a table mode: regenerated", written == [logo_of("1280x720")] and os.path.isfile(logo_of("1280x720")), written)

            # --- no slot in the kernel command line: only the ESP logo
            open(cmdline, "w").write("BOOT_IMAGE=/vmlinuz quiet\n")
            set_mode("1000x700")
            written = uu.ensure_boot_pictures(conf)
            check("no unitotem.slot on the command line: only the ESP logo is written",
                  written == [logo_of("1000x700")] and not os.path.exists(slot_of("1000x700")), written)
            open(cmdline, "w").write("BOOT_IMAGE=/vmlinuz unitotem.slot=a quiet\n")

            # --- hostile modes: nothing generated, nothing written, one event each
            orig_get = uu.grubenv_get
            for raw in HOSTILE:
                uu.grubenv_get = (lambda r: (lambda c, k: r))(raw)
                before_tree = tree_files(); before_ev = len(event_text())
                try:
                    r = uu.ensure_boot_pictures(conf)
                finally:
                    uu.grubenv_get = orig_get
                check(f"hostile mode {raw!r}: nothing returned, nothing written",
                      r == [] and tree_files() == before_tree, (r, tree_files() ^ before_tree))
                check(f"hostile mode {raw!r}: one event line", "boot picture not generated: bad display mode" in event_text()[before_ev:]
                      and event_text()[before_ev:].count("\n") == 1, event_text()[before_ev:])

            # --- generator kit missing: event, no exception, nothing half-written
            gone = dict(conf, UPDATE_BOOT_TOOL=os.path.join(real, "no-such-tool"))
            drop(logo_of("1440x900"), slot_of("1440x900"))
            set_mode("1440x900")
            before_ev = len(event_text())
            r = uu.ensure_boot_pictures(gone)
            check("tool missing: no exception, nothing returned, no picture",
                  r == [] and not os.path.exists(logo_of("1440x900")) and not os.path.exists(slot_of("1440x900")), r)
            check("tool missing: an event is logged", "generator kit missing" in event_text()[before_ev:], event_text()[before_ev:])

            # --- generator exits 1
            open(script, "w").write("import sys\nsys.stderr.write('boom: test stub\\n')\nsys.exit(1)\n")
            before_ev = len(event_text()); before_tree = tree_files()
            try:
                r = uu.ensure_boot_pictures(conf)
            finally:
                open(script, "wb").write(orig_script)
            check("generator exit 1: nothing returned, no picture, no .new file",
                  r == [] and tree_files() == before_tree, r)
            check("generator exit 1: the event names the exit status and the stderr line",
                  "generator exit 1: boom: test stub" in event_text()[before_ev:], event_text()[before_ev:])

            # --- generator hangs: timeout of 2 s, event, nothing written
            open(script, "w").write("import time\ntime.sleep(30)\n")
            before_ev = len(event_text()); before_tree = tree_files()
            t0 = time.monotonic()
            try:
                r = uu.ensure_boot_pictures(dict(conf, UPDATE_BOOT_TOOL_TIMEOUT="2"))
            finally:
                open(script, "wb").write(orig_script)
            elapsed = time.monotonic() - t0
            check("generator hangs: returns after the 2 s timeout", elapsed < 20, f"{elapsed:.1f}s")
            check("generator hangs: event logged, nothing written", r == [] and tree_files() == before_tree
                  and "timed out after 2 s" in event_text()[before_ev:], (r, event_text()[before_ev:]))

            # --- read-only mount: remount rw, write, sync, remount ro; writable mount: no remount
            set_mode("1024x768")
            drop(slot_of("1024x768"))
            calls.clear()
            r = uu.ensure_boot_pictures(conf)
            check("read-only slot mount: slot picture written", r == [slot_of("1024x768")] or slot_of("1024x768") in r, r)
            check("read-only slot mount: remounted rw, synced, remounted ro in that order",
                  calls == [["mount", "-o", "remount,rw", rootfs], ["sync"], ["mount", "-o", "remount,ro", rootfs]], calls)
            with open(mounts, "w") as f:
                f.write(f"rootfs {rootfs} ext4 rw,relatime 0 0\n")
            drop(slot_of("1024x768"))
            calls.clear()
            r = uu.ensure_boot_pictures(conf)
            check("writable slot mount: picture written without any remount", slot_of("1024x768") in r and calls == [], (r, calls))
            with open(mounts, "w") as f:
                f.write(f"rootfs {rootfs} ext4 ro,relatime 0 0\n")

            calls.clear()
            try:
                with uu.mount_rw(conf, slotdir):
                    raise RuntimeError("body failed")
            except RuntimeError:
                pass
            check("mount_rw: remounted ro again when the block fails",
                  calls == [["mount", "-o", "remount,rw", rootfs], ["sync"], ["mount", "-o", "remount,ro", rootfs]], calls)

            drop(slot_of("1024x768"))
            mount_rc[0] = 1
            try:
                r = uu.ensure_boot_pictures(conf)
            finally:
                mount_rc[0] = 0
            check("remount refused: no exception, no picture, event logged",
                  r == [] and not os.path.exists(slot_of("1024x768")) and "cannot remount" in event_text(), r)

            # --- detached generation: sync_esp_grubcfg records the mode and starts the unit, never generates itself
            sysd = []
            sysd_fail = [None]

            def fake_run_out(*cmd, check=True):
                if cmd and cmd[0] == "systemd-run":
                    sysd.append(list(cmd))
                    if sysd_fail[0] is not None:
                        raise sysd_fail[0]
                    return ""
                return real_run_out(*cmd, check=check)

            uu.run_out = fake_run_out
            expect_unit = ["systemd-run", "--unit", "unitotem-boot-pictures", "--collect", "--quiet", "-p", "Nice=19",
                           "-p", "IOSchedulingClass=idle", "-p", "RuntimeMaxSec=90", sys.executable,
                           os.path.abspath(uu.__file__), "--json", "boot-pictures"]

            def reset_first_boot():
                real_run(["grub-editenv", genv, "unset", "unitotem_gfx"], check=True)
                drop(logo_of("1600x1000"), slot_of("1600x1000"))
                sysd.clear(); gen_calls.clear()

            def hold_lock():
                f = open(os.path.join(run, "unitotem-update.lock"), "a+")
                fcntl.flock(f, fcntl.LOCK_EX)
                f.write(str(os.getpid())); f.flush()          # as Lock does: the pid is what op_running reports
                return f

            first = displays(("card0-DP-1", "connected", "1600x1000\n"))
            reset_first_boot()
            check("first boot: grubenv has no mode before the call", uu.grubenv_get(first, "unitotem_gfx") == "")
            r = uu.sync_esp_grubcfg(first)
            check("first boot: sync reports no grub.cfg change (level unchanged)", r is None, r)
            check("first boot: the mode is recorded by the call", uu.grubenv_get(first, "unitotem_gfx") == "1600x1000")
            check("first boot: exactly one detached start with the exact unit arguments", sysd == [expect_unit], sysd)
            check("first boot: no picture written by the call",
                  not os.path.exists(logo_of("1600x1000")) and not os.path.exists(slot_of("1600x1000")))
            check("first boot: the generator did not run in the call", gen_calls == [], gen_calls)

            sysd.clear()
            uu.ensure_boot_pictures(first)              # pictures now present
            sysd.clear()
            uu.sync_esp_grubcfg(first)
            check("pictures present: no unit started", sysd == [], sysd)

            drop(logo_of("1600x1000"))
            sysd.clear()
            lockf = hold_lock()
            try:
                uu.sync_esp_grubcfg(first)
            finally:
                lockf.close()
            check("operation lock held: no unit started", sysd == [], sysd)
            check("operation lock held: the skip is logged", "another operation is running" in event_text())

            reset_first_boot()
            open(shipped, "w").write(cfg(7))
            sysd_fail[0] = uu.Fail("command-failed", "systemd-run: unit already running")
            try:
                r = uu.sync_esp_grubcfg(first)
            finally:
                sysd_fail[0] = None
            check("systemd-run fails: sync returns normally with the grub.cfg change", r == {"from": 6, "to": 7}, r)
            check("systemd-run fails: the failure is logged", "boot pictures not started: " in event_text()
                  and "unit already running" in event_text())
            check("systemd-run fails: grub.cfg still synced", read(target) == cfg(7).encode())
            open(target, "w").write(cfg(6)); open(shipped, "w").write(cfg(6))

            reset_first_boot()
            marker = os.path.join(real, "generator-ran")
            open(script, "w").write(f"open({marker!r}, 'w').close()\nimport time\ntime.sleep(30)\n")
            t0 = time.monotonic()
            try:
                uu.sync_esp_grubcfg(first)
            finally:
                open(script, "wb").write(orig_script)
            elapsed = time.monotonic() - t0
            check("generator stub sleeping 30 s: sync returns in under 2 s", elapsed < 2, f"{elapsed:.2f}s")
            check("generator stub: never run inside sync", not os.path.exists(marker))
            check("generator stub: the detached unit is started once", sysd == [expect_unit], sysd)

            # --- cmd_boot_pictures: the unit's entry point
            reset_first_boot()
            set_mode("1600x1000")
            r = uu.cmd_boot_pictures(argparse.Namespace(), conf)
            check("cmd_boot_pictures: rc 0, both pictures listed",
                  r[0] == 0 and sorted(r[1]["generated"]) == sorted([logo_of("1600x1000"), slot_of("1600x1000")]), r)
            check("cmd_boot_pictures: the logo is 1600x1000 and the generator's own output",
                  png_size(read(logo_of("1600x1000"))) == (1600, 1000)
                  and read(logo_of("1600x1000")) == read(direct("1600x1000", "logo")))
            check("cmd_boot_pictures: second run generates nothing", uu.cmd_boot_pictures(argparse.Namespace(), conf) == (0, {"generated": []}))
            drop(logo_of("1600x1000"))
            lockf = hold_lock()
            try:
                r = uu.cmd_boot_pictures(argparse.Namespace(), conf)
            finally:
                lockf.close()
            check("cmd_boot_pictures: busy lock is rc 0, skipped, nothing written",
                  r == (0, {"generated": [], "skipped": "busy"}) and not os.path.exists(logo_of("1600x1000")), r)
            uu.run_out = real_run_out
            check("temporary tree: the run directory holds only the lock file",
                  [n for n in os.listdir(run) if n != "unitotem-update.lock"] == [], os.listdir(run))
    finally:
        subprocess.run = real_run
        uu._generate_picture = real_gen
        uu.run_out = real_run_out

print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

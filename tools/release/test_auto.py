#!/usr/bin/env python3
"""Host-side test of the automatic update policy of unitotem-update (modes off/download/stage/reboot/scheduled). No device: the Raspberry
backend runs on a fake FAT directory, the server and the download are replaced by stubs, and the reboot is recorded instead of done.

  python3 tools/release/test_auto.py
"""
import argparse, datetime, importlib.machinery, importlib.util, json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "unitotem/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)

with tempfile.TemporaryDirectory() as td:
    bf = os.path.join(td, "firmware"); os.makedirs(bf + "/slota")
    open(bf + "/config.txt", "w").write("arm_64bit=1\n[all]\nos_prefix=slota/\nkernel=kernel8.img\n")
    dt = os.path.join(td, "dt"); os.makedirs(dt)
    state = os.path.join(td, "state"); run = os.path.join(td, "run"); os.makedirs(run); os.makedirs(os.path.join(td, "data"))
    cmdline = os.path.join(td, "cmdline"); open(cmdline, "w").write("root=LABEL=ROOT_A unitotem.slot=a\n")
    verf = os.path.join(td, "version"); open(verf, "w").write("2026.10.30\n")
    conf = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="rpi", UPDATE_BOOTFS=bf, UPDATE_DT_BOOTLOADER=dt, UPDATE_STATE_DIR=state,
                UPDATE_RUN_DIR=run, UPDATE_CMDLINE=cmdline, UPDATE_DATA=os.path.join(td, "data"), UPDATE_HEALTH_URL="",
                UPDATE_VERSION_FILE=verf, UPDATE_ETC_CURRENT=os.path.join(td, "etc"))
    os.makedirs(conf["UPDATE_ETC_CURRENT"])

    log = {"fetch": 0, "reboot": [], "check": 0}
    available = {"v": True}

    def fake_check(a, c):
        log["check"] += 1
        return (0, {"available": True, "version": "2026.10.34", "needs_layout_migration": False}) if available["v"] \
            else (10, {"available": False, "version": "2026.10.30", "needs_layout_migration": False})

    def fake_fetch(a, c):
        log["fetch"] += 1
        st = uu.slots_state(c); st["b"] = {"version": "2026.10.34", "valid": True, "prepared": True}; uu.write_state(c, "slots.json", st)
        return 0, {}

    uu.cmd_check = fake_check; uu.do_fetch = fake_fetch
    uu.slot_check = lambda *a: None
    uu.import_whitelist = lambda *a, **k: 0
    uu.merge_identity_into = lambda *a, **k: {}
    uu.be_reboot = lambda c, trial=False, delay=3: log["reboot"].append(trial)
    uu._uptime_s = lambda: 1e6
    A = argparse.Namespace(now=False)

    def reset():
        for n in ("auto.json", "auto-state.json", "pending.json", "slots.json"):
            try: os.unlink(os.path.join(state, n))
            except OSError: pass
        try: os.unlink(os.path.join(bf, "tryboot.txt"))
        except OSError: pass
        log.update(fetch=0, reboot=[], check=0); available["v"] = True

    def pol(mode, t="04:00"):
        uu.write_state(conf, "auto.json", {"mode": mode, "time": t})

    # --- policy command validates
    reset()
    rc, out = uu.cmd_policy(argparse.Namespace(set_mode="stage", time="03:30"), conf)
    check("policy: set and read back", out["policy"] == {"mode": "stage", "time": "03:30"}, out)
    for bad in (dict(set_mode="sometimes", time=None), dict(set_mode=None, time="25:00"), dict(set_mode=None, time="4:00")):
        try: uu.cmd_policy(argparse.Namespace(**bad), conf); check("policy: rejects %s" % bad, False)
        except uu.Fail: check("policy: rejects %s" % bad, True)
    check("policy: default is off", (reset(), uu.auto_policy(conf)["mode"])[1] == "off")

    # --- off
    reset(); pol("off"); uu.cmd_auto(A, conf)
    check("off: nothing happens", log["check"] == 0 and log["fetch"] == 0 and not log["reboot"])

    # --- download only
    reset(); pol("download"); rc, out = uu.cmd_auto(A, conf)
    check("download: fetched, nothing armed, no reboot", log["fetch"] == 1 and not os.path.exists(os.path.join(state, "pending.json")) and not log["reboot"], out)
    uu.cmd_auto(A, conf)
    check("download: a second tick does not fetch again", log["fetch"] == 1)

    # --- stage: armed, not rebooted, waits
    reset(); pol("stage"); rc, out = uu.cmd_auto(A, conf)
    pend = uu.read_state(conf, "pending.json") or {}
    check("stage: armed as staged for slot b", pend.get("slot") == "b" and pend.get("staged") is True, pend)
    check("stage: tryboot.txt written (Raspberry) and NO reboot", os.path.exists(os.path.join(bf, "tryboot.txt")) and not log["reboot"])
    uu.cmd_auto(A, conf)
    check("stage: later ticks leave it waiting", not log["reboot"] and log["fetch"] == 1)
    rc, st = uu.cmd_status(argparse.Namespace(), conf)
    check("status shows the staged update and the policy", st.get("staged") is True and st["auto"]["policy"]["mode"] == "stage", st.get("armed"))
    # a boot of the OLD slot before any tryboot request is not a failed trial
    uu.cmd_boot_ok(argparse.Namespace(), conf)
    check("boot-ok on the old slot keeps a staged update", (uu.read_state(conf, "pending.json") or {}).get("slot") == "b")
    uu.cmd_reboot(argparse.Namespace(), conf)
    check("reboot command: tryboot reboot into the staged update", log["reboot"] == [True] and uu.read_state(conf, "pending.json").get("trial_requested") is True)
    uu.cmd_boot_ok(argparse.Namespace(), conf)
    check("after a requested trial that did not come back, the normal rollback path runs", uu.read_state(conf, "pending.json") is None)

    # --- reboot mode
    reset(); pol("reboot"); uu.cmd_auto(A, conf)
    check("reboot: fetched, armed and rebooted into the trial", log["fetch"] == 1 and log["reboot"] == [True])

    # --- scheduled
    reset(); pol("scheduled", "04:00")
    uu._in_window = lambda now, hhmm: (False, "2026-10-27")
    rc, out = uu.cmd_auto(A, conf)
    check("scheduled: outside the window it is staged and does not reboot", not log["reboot"] and out["state"]["action"] == "staged", out)
    rc, out = uu.cmd_auto(A, conf)
    check("scheduled: still waiting", not log["reboot"] and out["state"]["action"] == "waiting-for-schedule", out)
    uu._in_window = lambda now, hhmm: (True, "2026-10-27")
    uu.cmd_auto(A, conf)
    check("scheduled: inside the window it reboots into the update", log["reboot"] == [True], log)
    # the same day never twice (the staged update is still there if the reboot did not take)
    pend = uu.read_state(conf, "pending.json"); pend["trial_requested"] = False; uu.write_state(conf, "pending.json", pend)
    uu.cmd_auto(A, conf)
    check("scheduled: at most one reboot request per day", log["reboot"] == [True])

    # real window arithmetic
    uu2 = importlib.util.module_from_spec(spec); loader.exec_module(uu2)
    t = datetime.datetime(2026, 10, 27, 4, 20)
    check("window: 04:20 is inside the 04:00 window", uu2._in_window(t, "04:00")[0])
    check("window: 05:10 is outside", not uu2._in_window(datetime.datetime(2026, 10, 27, 5, 10), "04:00")[0])
    check("window: 03:59 is outside (the window is tomorrow's)", not uu2._in_window(datetime.datetime(2026, 10, 27, 3, 59), "04:00")[0])
    check("window across midnight: 00:10 is inside the 23:30 window of the day before", uu2._in_window(datetime.datetime(2026, 10, 28, 0, 10), "23:30") == (True, "2026-10-27"))

    # --- guards
    reset(); pol("reboot"); uu._uptime_s = lambda: 30
    rc, out = uu.cmd_auto(A, conf)
    check("settle: right after boot nothing is done", out["state"]["action"] == "settling" and log["check"] == 0)
    uu._uptime_s = lambda: 1e6
    uu.write_state(conf, "pending.json", {"slot": "a", "from": "b", "version": "x"})
    rc, out = uu.cmd_auto(A, conf)
    check("a running trial is never disturbed", out["state"]["action"] == "trial-running" and log["check"] == 0)
    os.unlink(os.path.join(state, "pending.json"))
    available["v"] = False; reset(); available["v"] = False; pol("reboot")
    rc, out = uu.cmd_auto(A, conf)
    check("nothing newer: nothing happens", out["state"]["action"] == "up-to-date" and not log["reboot"] and log["fetch"] == 0)
    uu.cmd_auto(A, conf)
    check("rate limit: the second tick does not ask the server again", log["check"] == 1, log)
    reset(); pol("reboot")
    def bad_fetch(a, c): raise uu.Fail("network", "down")
    uu.do_fetch = bad_fetch
    rc, out = uu.cmd_auto(A, conf)
    check("a failed download backs off and does not reboot", out["state"]["action"] == "fetch-failed" and not log["reboot"])
    rc, out = uu.cmd_auto(A, conf)
    check("the next tick waits (backoff)", out["state"]["action"] == "backoff")

    # --- blank B (first boot, the layout created it and nothing was written): the policy fetches onto it like onto any empty slot,
    # and nothing is armed before the fetch has verified it
    uu.do_fetch = fake_fetch
    reset(); pol("download")
    rc, out = uu.cmd_auto(A, conf)
    check("blank B: the update is fetched onto it", log["fetch"] == 1 and out["state"]["action"] == "downloaded", (log, out))
    reset()
    try:
        uu.auto_arm(conf)
        armed_blank = True
    except uu.Fail as e:
        armed_blank = e.code == "nothing-fetched"
    check("blank B: nothing is armed before a verified fetch", armed_blank)
    check("blank B: no pending update was written", not os.path.exists(os.path.join(state, "pending.json")))

    # --- auto repair tick: starts the repair only for a blank or unprepared other slot, on a healthy running system
    TK = {"cause": "first-boot", "health": True, "op": None, "repairs": [], "events": []}
    saved_tk = {n: getattr(uu, n) for n in ("cur_slot", "op_running", "health_ok", "_repair_sound", "slots_state", "cmd_repair", "event")}
    saved_tick = uu.auto_repair_tick
    uu.cur_slot = lambda c: "a"
    uu.op_running = lambda c: TK["op"]
    uu.health_ok = lambda c: TK["health"]
    uu._repair_sound = lambda c, st, s: (False, TK["cause"])
    uu.slots_state = lambda c: {"a": {"version": "2026.10.30", "valid": True}, "b": {"version": None, "valid": False}}
    uu.cmd_repair = lambda a, c: (TK["repairs"].append(a), (0, {"started": True}))[1]
    uu.event = lambda c, text: TK["events"].append(text)

    def tick(cause="first-boot", pending=False, op=None, health=True, autorepair="1", last=None):
        for n in ("pending.json", "last-result.json"):
            try: os.unlink(os.path.join(state, n))
            except OSError: pass
        if pending: uu.write_state(conf, "pending.json", {"slot": "b", "from": "a", "version": "x"})
        if last is not None: uu.write_state(conf, "last-result.json", last)
        TK.update(cause=cause, op=op, health=health, repairs=[], events=[])
        uu.auto_repair_tick(dict(conf, UPDATE_AUTOREPAIR=autorepair))
        return len(TK["repairs"]) == 1 and TK["repairs"][0].auto is True

    def utc_ago(s):
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - s))

    failed_repair = lambda at: {"op": "repair", "result": "failed", "error_code": "write-failed", "at": at}
    try:
        check("tick: first-boot other slot starts the repair", tick("first-boot"))
        check("tick: unprepared other slot starts the repair", tick("unprepared"))
        check("tick: label cause does not start it", not tick("label"))
        check("tick: fsck cause does not start it", not tick("fsck"))
        check("tick: empty cause does not start it", not tick("empty"))
        check("tick: a pending update does not start it", not tick(pending=True))
        check("tick: a running operation does not start it", not tick(op=4242))
        check("tick: a failed health check does not start it", not tick(health=False))
        check("tick: UPDATE_AUTOREPAIR=0 does not start it", not tick(autorepair="0"))
        check("tick: a repair failed 5 min ago is not retried", not tick(last=failed_repair(utc_ago(300))))
        check("tick: a repair failed 2 h ago is retried", tick(last=failed_repair(utc_ago(7200))))
        check("tick: a successful last repair does not block it", tick(last={"op": "repair", "result": "ok", "at": utc_ago(60)}))
        check("tick: the start is logged", tick() and any("auto: repair of slot b" in t for t in TK["events"]), TK["events"])

        # cmd_auto runs the tick before its policy, also with the policy off, and returns the policy's own result
        calls_tk = []
        uu.auto_repair_tick = lambda c: calls_tk.append(1)
        pol("off")
        rc, out = uu.cmd_auto(A, conf)
        check("cmd_auto: policy off still calls the tick and returns its usual result",
              calls_tk == [1] and rc == 0 and out["state"]["action"] == "off", (calls_tk, out))
        uu.auto_repair_tick = saved_tick

        # an error inside the tick is logged and does not stop cmd_auto
        def boom(c): raise RuntimeError("boom")               # health_ok: reached by the tick only, not by cmd_auto in off mode
        uu.health_ok = boom
        TK["events"] = []
        pol("off")
        try:
            rc, out = uu.cmd_auto(A, conf); survived = True
        except Exception as e:
            survived = False; out = repr(e)
        uu.health_ok = lambda c: TK["health"]
        check("cmd_auto: an exception in the tick does not break cmd_auto", survived and rc == 0 and out["state"]["action"] == "off", out)
        check("cmd_auto: the tick error is logged", any("auto repair not started: boom" in t for t in TK["events"]), TK["events"])
    finally:
        for n, v in saved_tk.items(): setattr(uu, n, v)
        uu.auto_repair_tick = saved_tick

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

#!/usr/bin/env python3
"""Host-side test of the self-repair pieces of unitotem-update that need no block device: the Raspberry boot-file clone, the
failover guard bookkeeping, and the decision of when a repair runs. The partclone copy itself is proven on a VM/hardware.

  python3 tools/release/test_repair.py
"""
import importlib.machinery, importlib.util, os, sys, tempfile, argparse

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
    bf = os.path.join(td, "firmware"); os.makedirs(bf + "/slota/overlays")
    for f in ("kernel8.img", "initramfs8", "overlays/vc4.dtbo"): open(f"{bf}/slota/{f}", "w").write("x" * 100)
    open(bf + "/slota/cmdline.txt", "w").write("console=tty1 root=LABEL=ROOT_A rootwait ro quiet unitotem.slot=a\n")
    state = os.path.join(td, "state"); run = os.path.join(td, "run"); os.makedirs(run)
    cmdline = os.path.join(td, "cmdline"); open(cmdline, "w").write("root=LABEL=ROOT_A unitotem.slot=a\n")
    dt = os.path.join(td, "dt"); os.makedirs(dt)
    conf = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="rpi", UPDATE_BOOTFS=bf, UPDATE_DT_BOOTLOADER=dt, UPDATE_STATE_DIR=state,
                UPDATE_RUN_DIR=run, UPDATE_CMDLINE=cmdline, UPDATE_DATA=os.path.join(td, "data"), UPDATE_HEALTH_URL="")

    # --- boot files of the damaged slot are rebuilt from the running one, with the right root=/slot
    os.makedirs(bf + "/slotb"); open(bf + "/slotb/kernel8.img", "w").write("")           # a truncated leftover
    uu.rpi_clone_bootfiles(conf, "a", "b")
    cm = open(bf + "/slotb/cmdline.txt").read()
    check("clone: root= is the new slot's", "root=LABEL=ROOT_B" in cm and "ROOT_A" not in cm, cm)
    check("clone: unitotem.slot= is the new slot's", "unitotem.slot=b" in cm and "unitotem.slot=a" not in cm, cm)
    check("clone: kernel/initramfs/overlays copied", all(os.path.getsize(f"{bf}/slotb/{f}") == 100 for f in ("kernel8.img", "initramfs8", "overlays/vc4.dtbo")))
    check("clone: no .new/.old leftovers", not os.path.exists(bf + "/slotb.new") and not os.path.exists(bf + "/slotb.old"))
    check("clone: source slot untouched", "ROOT_A" in open(bf + "/slota/cmdline.txt").read())

    # --- failover guard: reported once, then removed
    guard = os.path.join(bf, "unitotem-ota.failover"); open(guard, "w").write("a->b\n")
    uu.note_failover(conf)
    lr = uu.read_state(conf, "last-result.json") or {}
    check("failover: recorded in last-result", lr.get("op") == "failover" and lr.get("detail") == "a->b", lr)
    check("failover: guard removed", not os.path.exists(guard))
    uu.note_failover(conf)                                    # no guard: silent no-op
    check("failover: no guard is a no-op", True)

    # --- when does a repair run?
    uu.slot_sound = lambda c, s: (False, "fsck")
    st = uu.slots_state(conf)
    st["b"] = {"version": None, "valid": False}; uu.write_state(conf, "slots.json", st)
    rc, out = uu.do_repair(argparse.Namespace(auto=True, force=False, foreground=True), conf)
    check("auto: a slot that never held a system is not 'damaged'", out.get("repaired") is False and "nothing to repair" in out.get("reason", ""), out)
    uu.slot_sound = lambda c, s: (True, "ok")
    st["b"] = {"version": "1", "valid": True}; uu.write_state(conf, "slots.json", st)
    rc, out = uu.do_repair(argparse.Namespace(auto=True, force=False, foreground=True), conf)
    check("auto: a sound other slot is left alone", out.get("repaired") is False and "sound" in out.get("reason", ""), out)

    # --- the ESP's grub.cfg follows the image, never backwards
    esp = os.path.join(td, "esp"); os.makedirs(esp + "/unitotem-grub/grub")
    shipped = os.path.join(td, "esp-grub.cfg")
    cfg = lambda lvl: (f"# unitotem-grub-level: {lvl}\n" if lvl else "") + "menuentry 'A' --id slot-a {}\nmenuentry 'B' --id slot-b {}\nmenuentry 'O' --id ota-recovery {}\n"
    gconf = dict(conf, UPDATE_BACKEND="grub", UPDATE_ESP_MOUNT=esp, UPDATE_ESP_GRUBCFG=shipped)
    target = esp + "/unitotem-grub/grub/grub.cfg"
    open(target, "w").write(cfg(0)); open(shipped, "w").write(cfg(2))
    r = uu.sync_esp_grubcfg(gconf)
    check("grub.cfg sync: older ESP config is replaced", r == {"from": 0, "to": 2} and open(target).read() == cfg(2), r)
    check("grub.cfg sync: no .new left behind", not os.path.exists(target + ".new"))
    check("grub.cfg sync: same level is left alone", uu.sync_esp_grubcfg(gconf) is None)
    open(shipped, "w").write(cfg(1))
    check("grub.cfg sync: a rollback to an older image never downgrades", uu.sync_esp_grubcfg(gconf) is None and open(target).read() == cfg(2))
    open(shipped, "w").write("# unitotem-grub-level: 3\nmenuentry 'A' --id slot-a {}\n")
    check("grub.cfg sync: an incomplete config is refused", uu.sync_esp_grubcfg(gconf) is None and open(target).read() == cfg(2))

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

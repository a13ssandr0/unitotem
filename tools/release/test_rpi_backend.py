#!/usr/bin/env python3
"""Host-side test of unitotem-update's Raspberry backend. No Raspberry, no root, no loop devices:
a fake FAT-like directory stands in for /boot/firmware, a synthetic GPT image (FAT + ext4 built with
mtools/mke2fs and dd'd into place) feeds `unitotem-release build-ab --arch arm64`, and fake-github.py
serves the result. What it does NOT prove: that the Pi firmware honours os_prefix / tryboot.txt.

  python3 tools/release/test_rpi_backend.py
"""
import importlib.machinery, importlib.util, json, os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def sh(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "kiosk/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)

with tempfile.TemporaryDirectory() as td:
    bf = os.path.join(td, "firmware"); os.makedirs(bf + "/slota")
    open(bf + "/config.txt", "w").write("arm_64bit=1\n[all]\nos_prefix=slota/\nkernel=kernel8.img\ninitramfs initramfs8 followkernel\n[pi4]\narm_boost=1\n")
    for f in ("kernel8.img", "initramfs8"): open(f"{bf}/slota/{f}", "w").write("x" * 100)
    open(bf + "/slota/cmdline.txt", "w").write("console=tty1 root=LABEL=ROOT_A rootfstype=ext4 rootwait ro quiet unitotem.slot=a\n")
    dt = os.path.join(td, "dt"); os.makedirs(dt)
    state = os.path.join(td, "state"); run = os.path.join(td, "run"); os.makedirs(run)
    cmdline = os.path.join(td, "cmdline"); open(cmdline, "w").write("root=LABEL=ROOT_A unitotem.slot=a\n")
    reboots = os.path.join(td, "reboots")
    conf = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="rpi", UPDATE_BOOTFS=bf, UPDATE_DT_BOOTLOADER=dt, UPDATE_STATE_DIR=state,
                UPDATE_RUN_DIR=run, UPDATE_CMDLINE=cmdline, UPDATE_DATA=os.path.join(td, "data"),
                UPDATE_REBOOT_CMD=f"echo trial=$UNITOTEM_REBOOT_TRIAL >> {reboots}", UPDATE_HEALTH_URL="")

    uu.slot_check = lambda *a: None      # no real block device here
    check("backend rpi riconosciuto", uu.need_backend(conf) == "rpi")
    check("default slot letto da os_prefix", uu.be_default_slot(conf) == "a")

    # board without the EEPROM bootloader -> unsupported
    try: uu.need_backend(dict(conf, UPDATE_DT_BOOTLOADER=os.path.join(td, "nope"))); check("senza tryboot rifiutata", False)
    except uu.Fail as e: check("senza tryboot rifiutata", e.code == "backend-unsupported")

    # apply without reboot is refused on Raspberry
    st = {"a": {"version": "1", "valid": True, "confirmed": True}, "b": {"version": "2", "valid": True, "prepared": True}}
    uu.write_state(conf, "slots.json", st)
    class A: reboot = False; json = True
    try: uu.cmd_apply(A, conf); check("apply senza --reboot rifiutato", False)
    except uu.Fail as e: check("apply senza --reboot rifiutato", e.code == "needs-reboot")
    check("... e non lascia tryboot.txt", not os.path.exists(bf + "/tryboot.txt"))

    class B: reboot = True; json = True
    rc, out = uu.cmd_apply(B, conf)
    tb = open(bf + "/tryboot.txt").read()
    check("apply scrive tryboot.txt con os_prefix=slotb/", "os_prefix=slotb/" in tb and "os_prefix=slota/" not in tb)
    check("tryboot.txt conserva il resto della config", "[pi4]\narm_boost=1" in tb and "initramfs initramfs8 followkernel" in tb)
    check("config.txt (default) intatto durante la prova", "os_prefix=slota/" in open(bf + "/config.txt").read())
    time.sleep(0.3)
    check("riavvio di prova richiesto (tryboot)", "trial=1" in (open(reboots).read() if os.path.exists(reboots) else ""))

    # now "booted into b": confirm promotes
    open(cmdline, "w").write("root=LABEL=ROOT_B unitotem.slot=b\n")
    out = uu.confirm_now(conf)
    check("confirm: config.txt punta a slotb", "os_prefix=slotb/" in open(bf + "/config.txt").read())
    check("confirm: tryboot.txt rimosso", not os.path.exists(bf + "/tryboot.txt"))
    check("confirm: default letto = b", uu.be_default_slot(conf) == "b")

    # rollback
    class R: reboot = True; json = True
    rc, out = uu.cmd_rollback(R, conf)
    check("rollback: config.txt torna a slota", "os_prefix=slota/" in open(bf + "/config.txt").read())
    time.sleep(0.3)
    check("rollback: riavvio normale (non tryboot)", open(reboots).read().strip().splitlines()[-1] == "trial=0")

    # whitelist import is repeatable: a change made between fetch and apply must reach the new slot
    data = conf["UPDATE_DATA"]; os.makedirs(data + "/upper/etc.a/unitotem"); os.makedirs(data + "/upper/etc.b")
    open(data + "/upper/etc.a/unitotem/update.conf", "w").write("v1\n")
    open(data + "/upper/etc.a/hostname", "w").write("kiosk\n")
    pl = os.path.join(td, "pl"); open(pl, "w").write("# c\nhostname\nunitotem*\nunitotem*/**\n")
    n1 = uu.import_whitelist(conf, "b", "a", pl)
    open(data + "/upper/etc.a/unitotem/update.conf", "w").write("v2\n")
    uu.import_whitelist(conf, "b", "a", pl)
    check("whitelist: prima importazione", n1 >= 2 and open(data + "/upper/etc.b/hostname").read() == "kiosk\n")
    check("whitelist: reimportazione sovrascrive (modifica tra fetch e apply)", open(data + "/upper/etc.b/unitotem/update.conf").read() == "v2\n")

    # ---- release builder (arm64) + bootfiles install, via the fake server ----
    img = os.path.join(td, "arm.img")
    sh("truncate", "-s", "400M", img)
    sh("sgdisk", "-Z", img); sh("sgdisk", "-n", "1:2048:+64M", "-t", "1:0700", "-c", "1:FIRMWARE", img)
    sh("sgdisk", "-n", "2:0:+64M", "-t", "2:8300", "-c", "2:ROOT_A", img)
    fat = os.path.join(td, "fat.img"); sh("mkfs.fat", "-C", "-F32", "-n", "FIRMWARE", fat, "65536")
    src = os.path.join(td, "slotsrc"); os.makedirs(src + "/overlays")
    for f, c in (("kernel8.img", "K" * 5000), ("initramfs8", "I" * 7000), ("bcm2711-rpi-4-b.dtb", "D" * 300), ("overlays/vc4.dtbo", "O" * 80),
                 ("cmdline.txt", "console=tty1 root=LABEL=ROOT_A unitotem.slot=a\n")):
        open(os.path.join(src, f), "w").write(c)
    sh("mmd", "-i", fat, "::slota"); sh("mcopy", "-s", "-i", fat, src + "/.", "::slota/") if False else None
    for f in ("kernel8.img", "initramfs8", "bcm2711-rpi-4-b.dtb", "cmdline.txt"): sh("mcopy", "-i", fat, os.path.join(src, f), "::slota/")
    sh("mmd", "-i", fat, "::slota/overlays"); sh("mcopy", "-i", fat, src + "/overlays/vc4.dtbo", "::slota/overlays/")
    rootdir = os.path.join(td, "rootdir"); os.makedirs(rootdir + "/usr/share/unitotem"); open(rootdir + "/usr/share/unitotem/release-version", "w").write("9.9.9\n")
    ext = os.path.join(td, "ext.img"); sh("truncate", "-s", "64M", ext); sh("mke2fs", "-q", "-t", "ext4", "-L", "ROOT_A", "-d", rootdir, ext)
    for p, f in ((1, fat), (2, ext)):
        info = sh("sgdisk", "-i", str(p), img).stdout
        first = int(next(l for l in info.splitlines() if l.startswith("First sector")).split(":")[1].split()[0])
        sh("dd", f"if={f}", f"of={img}", "bs=512", f"seek={first}", "conv=notrunc", "status=none")

    keys = os.path.join(td, "keys"); rel = os.path.join(td, "rel")
    R_ = os.path.join(HERE, "unitotem-release")
    sh(R_, "keygen", "--dir", keys, "--name", "root"); sh(R_, "keygen", "--dir", keys, "--name", "release")
    sh(R_, "sign-keys", "--root-key", keys + "/root.key", "--pub", keys + "/release.pub", "--seq", "1", "--out", td + "/keys.json")
    sh(R_, "build-ab", "--image", img, "--version", "9.9.9", "--arch", "arm64", "--release-key", keys + "/release.key",
       "--keys-json", td + "/keys.json", "--out", rel)
    man = json.load(open(rel + "/v9.9.9/manifest.json"))
    check("release arm64 ha root e bootfiles", sorted(p["role"] for p in man["parts"]) == ["bootfiles", "root"])

    port = 18099
    srv = subprocess.Popen([sys.executable, os.path.join(HERE, "fake-github.py"), "--root", rel, "--bind", "127.0.0.1", "--port", str(port)],
                           stderr=subprocess.DEVNULL)
    try:
        time.sleep(1)
        base = f"http://127.0.0.1:{port}/o/r/releases/latest/download/"
        uu.rpi_install_bootfiles(conf, "a", "b", man, base)
        check("bootfiles installati in slotb/", all(os.path.isfile(f"{bf}/slotb/{f}") for f in ("kernel8.img", "initramfs8", "bcm2711-rpi-4-b.dtb", "overlays/vc4.dtbo")))
        cl = open(bf + "/slotb/cmdline.txt").read()
        check("cmdline.txt di slotb punta a ROOT_B e slot=b", "root=LABEL=ROOT_B" in cl and "unitotem.slot=b" in cl and "ROOT_A" not in cl, cl)
        check("nessuna directory temporanea residua", not any(n.endswith((".new", ".old")) for n in os.listdir(bf)))
        # corrupted asset is refused and leaves nothing behind
        bad = dict(man, parts=[dict(p, sha256="0" * 64) if p["role"] == "bootfiles" else p for p in man["parts"]])
        try: uu.rpi_install_bootfiles(conf, "a", "b", bad, base); check("asset corrotto rifiutato", False)
        except uu.Fail as e: check("asset corrotto rifiutato", e.code == "bad-checksum")
        check("... senza toccare slotb esistente", os.path.isfile(bf + "/slotb/kernel8.img") and not os.path.exists(bf + "/slotb.new"))
    finally:
        srv.terminate()

print(f"\n{ok} passati, {fail} falliti")
sys.exit(1 if fail else 0)

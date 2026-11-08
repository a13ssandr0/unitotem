#!/usr/bin/env python3
"""Host-side test of the boot-partition recovery refresh (sync_boot_recovery in unitotem-update, see docs/system/boot.md).
Covers both backends (grub: ESP, rpi: firmware FAT): level gate, copy and verify, power cuts between the renames and
before recovery.sha256, refusals, stray .new files, the call sites (trial boot never syncs), the status field.
Every path is a tempfile directory; mount/umount are refused by a guard. No block device is touched.

  PYTHONDONTWRITEBYTECODE=1 python3 tools/release/test_boot_recovery.py
"""
import argparse, contextlib, hashlib, importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
UU = os.path.join(ROOT, "unitotem/files/unitotem-update")
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


loader = importlib.machinery.SourceFileLoader("uu", UU)
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)

OLD_LEVEL, NEW_LEVEL = 100, 200
KERN_OLD, INITRD_OLD, DTB_OLD = b"OLD-KERNEL" * 40, b"OLD-INITRD" * 50, b"OLD-DTB" * 20
KERN_NEW, INITRD_NEW, DTB_NEW = b"NEW-KERNEL" * 41, b"NEW-INITRD" * 52, b"NEW-DTB" * 21
DTB_NAME = "bcm2711-rpi-4-b.dtb"
KEEP_MTIME = 1_000_000_000
ROOTS = []                                     # every temp device, removed at the end


class PowerCut(BaseException):
    """The power goes off: not an Exception, so no cleanup handler runs."""


class Guard:
    """Stands in for the module's subprocess: refuses mount/umount and any spawned reboot (systemd-run, systemctl),
    delegates everything else."""
    refused = []

    def __getattr__(self, name):
        return getattr(subprocess, name)

    def run(self, cmd, *a, **k):
        if cmd and cmd[0] in ("mount", "umount", "systemctl", "systemd-run"):
            Guard.refused.append(list(cmd))
            raise RuntimeError(f"test refuses {cmd[0]}")
        return subprocess.run(cmd, *a, **k)

    def Popen(self, cmd, *a, **k):
        if cmd and cmd[0] in ("mount", "umount", "systemctl", "systemd-run"):
            Guard.refused.append(list(cmd))
            raise RuntimeError(f"test refuses {cmd[0]}")
        return subprocess.Popen(cmd, *a, **k)


@contextlib.contextmanager
def patched(obj, name, val):
    old = getattr(obj, name)
    setattr(obj, name, val)
    try:
        yield
    finally:
        setattr(obj, name, old)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def write(p, b):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(b)


def read(p):
    with open(p, "rb") as f:
        return f.read()


def tree(d):
    """{relpath: (sha256, mtime_ns)} of every file under D."""
    out = {}
    for dp, _, fns in os.walk(d):
        for f in fns:
            p = os.path.join(dp, f)
            out[os.path.relpath(p, d)] = (sha(read(p)), os.stat(p).st_mtime_ns)
    return out


def age(d):
    """Gives every file under D a fixed old mtime, so any rewrite shows up in tree()."""
    for dp, _, fns in os.walk(d):
        for f in fns:
            os.utime(os.path.join(dp, f), (KEEP_MTIME, KEEP_MTIME))


def make(be, dtb=False, img_level=NEW_LEVEL, cmdline="root=LABEL=ROOT_B unitotem.slot=b\n"):
    """A device with the OLD recovery set on its boot partition and an image carrying the NEW set in UPDATE_RECOVERY_DIR.
    Returns (root, conf, boot, fdir): boot = the partition root, fdir = where recovery.sha256 lives."""
    root = tempfile.mkdtemp(prefix=f"boot-recovery-{be}-")
    ROOTS.append(root)
    boot = os.path.join(root, "esp") if be == "grub" else os.path.join(root, "fw")
    fdir = os.path.join(boot, "unitotem") if be == "grub" else boot
    rdir = os.path.join(root, "image")
    for d in (os.path.join(root, "state"), os.path.join(root, "run"), os.path.join(root, "dt"), fdir, rdir):
        os.makedirs(d, exist_ok=True)
    # the image's set
    write(os.path.join(rdir, "vmlinuz"), KERN_NEW)
    write(os.path.join(rdir, "initrd.img"), INITRD_NEW)
    lines = [f"# unitotem-recovery-level: {img_level}", f"{sha(KERN_NEW)}  vmlinuz", f"{sha(INITRD_NEW)}  initrd.img"]
    if dtb:
        write(os.path.join(rdir, "dtb", DTB_NAME), DTB_NEW)
        lines.append(f"{sha(DTB_NEW)}  dtb/{DTB_NAME}")
    write(os.path.join(rdir, "manifest"), ("\n".join(lines) + "\n").encode())
    # the device's OLD set
    kern_name = uu.recovery_fat_name(be, "vmlinuz")
    old = [(kern_name, KERN_OLD), ("recovery-initrd.img", INITRD_OLD)]
    if be == "rpi" and dtb:
        old.append((DTB_NAME, DTB_OLD))
    for name, data in old:
        write(os.path.join(fdir, name), data)
    write(os.path.join(fdir, "recovery.sha256"), recovery_text(OLD_LEVEL, [(n, sha(d)) for n, d in old]).encode())
    # everything the refresh must never touch
    if be == "grub":
        for rel, data in (("unitotem-grub/grub/grub.cfg", b"# unitotem-grub-level: 1\n"), ("unitotem-grub/grub/grubenv", b"# GRUB Environment Block\n")):
            write(os.path.join(boot, rel), data)
    else:
        for rel, data in (("config.txt", b"os_prefix=slota/\n[all]\nkernel=recovery8.img\n"), ("tryboot.txt", b"os_prefix=slotb/\n"),
                          ("cmdline.txt", b"console=tty1 root=LABEL=ROOT_A rootwait\n"), ("start4.elf", b"FIRMWARE-START4-ON-DEVICE"),
                          ("fixup4.dat", b"FIRMWARE-FIXUP4-ON-DEVICE"), ("slota/kernel8.img", b"SLOT-A-KERNEL"),
                          ("slota/cmdline.txt", b"root=LABEL=ROOT_A unitotem.slot=a\n"), ("overlays/vc4-kms-v3d.dtbo", b"OVL")):
            write(os.path.join(boot, rel), data)
    cmd = os.path.join(root, "cmdline")
    write(cmd, cmdline.encode())
    conf = dict(uu.CONF_DEFAULTS,
                UPDATE_BACKEND=be, UPDATE_STATE_DIR=os.path.join(root, "state"), UPDATE_RUN_DIR=os.path.join(root, "run"),
                UPDATE_RECOVERY_DIR=rdir, UPDATE_CMDLINE=cmd, UPDATE_DT_BOOTLOADER=os.path.join(root, "dt"),
                UPDATE_VERSION_FILE=os.path.join(root, "version"), UPDATE_DATA=os.path.join(root, "data"),
                UPDATE_ESP_MOUNT=os.path.join(root, "esp"), UPDATE_BOOTFS=os.path.join(root, "fw"),
                UPDATE_GRUBENV=os.path.join(root, "esp", "unitotem-grub", "grub", "grubenv"),
                UPDATE_ESP_GRUBCFG=os.path.join(root, "absent-esp-grub.cfg"),
                UPDATE_HEALTH_URL="", UPDATE_HEALTH_TIMEOUT="0", UPDATE_REBOOT_CMD="", UPDATE_AUTOREPAIR="0")
    return root, conf, boot, fdir


def recovery_text(level, pairs):
    return f"# unitotem-recovery-level: {level}\n" + "".join(f"{h}  {n}\n" for n, h in pairs)


def sync(conf):
    return uu.sync_boot_recovery(conf)


def state_rec(conf):
    return json.load(open(os.path.join(conf["UPDATE_STATE_DIR"], "recovery-sync.json")))


def fat_matches_image(be, boot, fdir, rdir, level):
    """Independent check: every FAT file equals the manifest sha, recovery.sha256 carries the level and the same lines."""
    lines = [l.split("  ", 1) for l in open(os.path.join(rdir, "manifest")).read().splitlines() if l and not l.startswith("#")]
    want = []
    for h, path in lines:
        if path == "vmlinuz": name = "recovery-vmlinuz" if be == "grub" else "recovery8.img"
        elif path == "initrd.img": name = "recovery-initrd.img"
        else: name = path[len("dtb/"):]
        want.append((name, h))
    for name, h in want:
        if sha(read(os.path.join(fdir, name))) != h:
            return False, f"{name} differs from the manifest"
    got = open(os.path.join(fdir, "recovery.sha256")).read()
    if got.splitlines()[0] != f"# unitotem-recovery-level: {level}":
        return False, "level line: " + got.splitlines()[0]
    if set(got.splitlines()[1:]) != {f"{h}  {n}" for n, h in want}:
        return False, "recovery.sha256 lines differ"
    return True, ""


def expected_new_names(be, dtb):
    names = [uu.recovery_fat_name(be, "vmlinuz"), "recovery-initrd.img"]
    if be == "rpi" and dtb:
        names.append(DTB_NAME)
    return names


def strays(fdir):
    return [f for f in os.listdir(fdir) if f.endswith(".new")]


# ---------------------------------------------------------------------------
def case_equal_level_noop(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
    r = sync(conf)
    check(f"{be}: first confirmed boot copies the newer set", r["result"] == "ok" and r["from"] == OLD_LEVEL and r["to"] == NEW_LEVEL, r)
    good, why = fat_matches_image(be, boot, fdir, conf["UPDATE_RECOVERY_DIR"], NEW_LEVEL)
    check(f"{be}: copied FAT files equal the manifest and recovery.sha256 lists them", good, why)
    check(f"{be}: no .new left after a complete run", not strays(fdir), strays(fdir))
    rc = subprocess.run(["sha256sum", "-c", "--quiet", "recovery.sha256"], cwd=fdir, capture_output=True, text=True)
    check(f"{be}: GNU sha256sum -c accepts recovery.sha256", rc.returncode == 0, rc.stdout + rc.stderr)
    check(f"{be}: state record ok", state_rec(conf)["result"] == "ok")
    # equal level: the first run writes the noop record once, the next runs must write nothing and hash nothing
    r2 = sync(conf)
    check(f"{be}: equal level is noop", r2["result"] == "noop" and r2["detail"] == "boot partition already holds this level", r2)
    age(boot); age(os.path.join(root, "state"))
    before, sbefore = tree(boot), tree(os.path.join(root, "state"))
    calls = []
    real = uu.sha256_file
    with patched(uu, "sha256_file", lambda p: (calls.append(p), real(p))[1]):
        r3 = sync(conf)
    check(f"{be}: equal level hashes nothing", calls == [], calls)
    check(f"{be}: equal level leaves boot partition bytes and mtimes unchanged", tree(boot) == before)
    check(f"{be}: steady state: a second noop writes no state file (recovery-sync.json mtime unchanged)", tree(os.path.join(root, "state")) == sbefore and r3["result"] == "noop", r3)


def case_lower_level_noop(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"), img_level=50)
    age(boot)
    before = tree(boot)
    calls = []
    real = uu.sha256_file
    with patched(uu, "sha256_file", lambda p: (calls.append(p), real(p))[1]):
        r = sync(conf)
    check(f"{be}: older image never downgrades the boot partition", r["result"] == "noop" and r["from"] == OLD_LEVEL and r["to"] == 50, r)
    check(f"{be}: older image: nothing hashed, nothing written", calls == [] and tree(boot) == before, calls)


def case_corrupt_copy(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
    age(boot)
    before = tree(boot)
    real = uu.sha256_file
    # the copy's re-read of every .new file mismatches
    with patched(uu, "sha256_file", lambda p: "0" * 64 if p.endswith(".new") else real(p)):
        r = sync(conf)
    check(f"{be}: corrupted copy is reported failed", r["result"] == "failed" and "does not verify" in r["detail"], r)
    check(f"{be}: corrupted copy leaves the old files byte-identical and unmodified", tree(boot) == before)
    check(f"{be}: corrupted copy leaves no .new", not strays(fdir), strays(fdir))


def case_image_mismatch(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
    rdir = conf["UPDATE_RECOVERY_DIR"]
    write(os.path.join(rdir, "initrd.img"), b"XX-NOT-THE-MANIFEST")
    age(boot)
    before = tree(boot)
    r = sync(conf)
    check(f"{be}: image file not matching its manifest is refused", r["result"] == "refused" and "initrd.img" in r["detail"], r)
    check(f"{be}: refused image leaves the boot partition untouched", tree(boot) == before)
    if be == "rpi":
        write(os.path.join(rdir, "initrd.img"), INITRD_NEW)
        write(os.path.join(rdir, "dtb", DTB_NAME), b"XX-DTB")
        r = sync(conf)
        check("rpi: image dtb not matching its manifest is refused", r["result"] == "refused" and DTB_NAME in r["detail"], r)
        check("rpi: refused dtb leaves the boot partition untouched", tree(boot) == before)


def case_cut_between_renames(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
    kern = uu.recovery_fat_name(be, "vmlinuz")
    real_replace = os.replace

    def cut_after_kernel(src, dst, *a, **k):
        real_replace(src, dst, *a, **k)
        if os.path.basename(dst) == kern:
            raise PowerCut()

    cut = False
    try:
        with patched(os, "replace", cut_after_kernel):
            sync(conf)
    except PowerCut:
        cut = True
    check(f"{be}: power cut injected between the kernel and the initrd rename", cut)
    check(f"{be}: after the cut the kernel is new", read(os.path.join(fdir, kern)) == KERN_NEW)
    check(f"{be}: after the cut the initrd is still old", read(os.path.join(fdir, "recovery-initrd.img")) == INITRD_OLD)
    check(f"{be}: after the cut recovery.sha256 is still old", uu.recovery_level(open(os.path.join(fdir, "recovery.sha256")).read()) == OLD_LEVEL)
    check(f"{be}: after the cut the copied initrd stays as .new (cleaned by the next run)", os.path.exists(os.path.join(fdir, "recovery-initrd.img.new")))
    r = sync(conf)
    n = 2 if (be == "rpi") else 1
    check(f"{be}: next confirmed boot finishes the set ({n} file(s) left)", r["result"] == "ok" and r["detail"] == f"{n} file(s) replaced" and r["from"] == OLD_LEVEL and r["to"] == NEW_LEVEL, r)
    good, why = fat_matches_image(be, boot, fdir, conf["UPDATE_RECOVERY_DIR"], NEW_LEVEL)
    check(f"{be}: after the finishing run all files equal the manifest and the level is raised", good, why)
    check(f"{be}: after the finishing run no .new left", not strays(fdir), strays(fdir))


def case_cut_before_sha(be):
    for variant in ("before-write", "before-rename"):
        root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
        real_replace = os.replace
        real_write = uu._write_verified

        def cut_write(path, text):
            if os.path.basename(path) == "recovery.sha256.new":
                raise PowerCut()
            return real_write(path, text)

        def cut_rename(src, dst, *a, **k):
            if os.path.basename(dst) == "recovery.sha256":
                raise PowerCut()
            return real_replace(src, dst, *a, **k)

        cut = False
        try:
            if variant == "before-write":
                with patched(uu, "_write_verified", cut_write):
                    sync(conf)
            else:
                with patched(os, "replace", cut_rename):
                    sync(conf)
        except PowerCut:
            cut = True
        check(f"{be}: power cut {variant} recovery.sha256", cut)
        check(f"{be}: {variant}: all set files already new, recovery.sha256 still old",
              all(read(os.path.join(fdir, n)) == (KERN_NEW if n == uu.recovery_fat_name(be, "vmlinuz") else INITRD_NEW if n == "recovery-initrd.img" else DTB_NEW)
                  for n in expected_new_names(be, dtb=(be == "rpi")))
              and uu.recovery_level(open(os.path.join(fdir, "recovery.sha256")).read()) == OLD_LEVEL)
        r = sync(conf)
        check(f"{be}: {variant}: next confirmed boot writes recovery.sha256 only", r["result"] == "ok" and r["detail"] == "0 file(s) replaced" and r["to"] == NEW_LEVEL, r)
        good, why = fat_matches_image(be, boot, fdir, conf["UPDATE_RECOVERY_DIR"], NEW_LEVEL)
        check(f"{be}: {variant}: finished, level raised, no .new", good and not strays(fdir), why or strays(fdir))


def case_stray_new_removed(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
    for n in (uu.recovery_fat_name(be, "vmlinuz"), "recovery-initrd.img", "recovery.sha256"):
        write(os.path.join(fdir, n + ".new"), b"stray from an earlier cut")
    r = sync(conf)
    check(f"{be}: stray .new files from an earlier cut are removed by the run", r["result"] == "ok" and not strays(fdir), (r, strays(fdir)))


def case_missing_manifest(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
    os.unlink(os.path.join(conf["UPDATE_RECOVERY_DIR"], "manifest"))
    age(boot)
    before = tree(boot)
    r = sync(conf)
    check(f"{be}: missing manifest is a noop", r["result"] == "noop" and r["detail"] == "no recovery set in the image", r)
    check(f"{be}: missing manifest leaves the boot partition untouched", tree(boot) == before)


def case_low_space(be):
    root, conf, boot, fdir = make(be, dtb=(be == "rpi"))
    age(boot)
    before = tree(boot)

    class Full:
        f_bavail = 0
        f_frsize = 4096

    with patched(os, "statvfs", lambda p: Full()):
        r = sync(conf)
    check(f"{be}: no free space on the boot partition: refused", r["result"] == "refused" and "free" in r["detail"], r)
    check(f"{be}: refused for space leaves the old files and no .new", tree(boot) == before and not strays(fdir))


def case_grub_dtb_refused():
    root, conf, boot, fdir = make("grub", dtb=True)
    age(boot)
    before = tree(boot)
    r = sync(conf)
    check("grub: an image carrying a dtb is refused (grub has no dtb files)", r["result"] == "refused" and "backend" in r["detail"], r)
    check("grub: refused dtb set leaves the ESP untouched", tree(boot) == before)


def case_rpi_firmware_not_synced():
    root, conf, boot, fdir = make("rpi", dtb=True)
    rdir = conf["UPDATE_RECOVERY_DIR"]
    # a manifest that names a firmware blob is not a set path: the whole manifest is ignored
    lines = open(os.path.join(rdir, "manifest")).read() + f"{sha(b'other')}  start4.elf\n"
    write(os.path.join(rdir, "manifest"), lines.encode())
    age(boot)
    before = tree(boot)
    r = sync(conf)
    check("rpi: a manifest naming start4.elf is not a recovery set (noop)", r["result"] == "noop", r)
    check("rpi: start4.elf and fixup4.dat stay byte-identical", read(os.path.join(boot, "start4.elf")) == b"FIRMWARE-START4-ON-DEVICE"
          and read(os.path.join(boot, "fixup4.dat")) == b"FIRMWARE-FIXUP4-ON-DEVICE" and tree(boot) == before)


def case_rpi_device_files_untouched():
    root, conf, boot, fdir = make("rpi", dtb=True)
    keep = [p for p in tree(boot) if p not in (uu.recovery_fat_name("rpi", "vmlinuz"), "recovery-initrd.img", DTB_NAME, "recovery.sha256")]
    before = tree(boot)
    r = sync(conf)
    check("rpi: refresh succeeds with a device-owned boot partition", r["result"] == "ok", r)
    after = tree(boot)
    check("rpi: config.txt, tryboot.txt, cmdline.txt, slota/, firmware and overlays are byte-identical",
          all(after[p] == before[p] for p in keep), [p for p in keep if after[p] != before[p]])
    check("rpi: top-level dtb copied from the image", read(os.path.join(boot, DTB_NAME)) == DTB_NEW)
    check("rpi: no other file was added to the boot partition", set(after) - set(before) <= {"recovery8.img", "recovery-initrd.img", DTB_NAME, "recovery.sha256"}
          and set(before) - set(after) == set(), (set(after) ^ set(before)))


def bsd(be):
    """The rpi default-slot switch runs for real on the temp config.txt; grub's switch would need a GRUB env block, so it is stubbed."""
    return patched(uu, "be_set_default", lambda c, s: None) if be == "grub" else contextlib.nullcontext()


def call_sites(be):
    """Trial boot never syncs; sync runs after confirm_now only (boot-ok health ok, cmd_confirm, plain boot)."""
    calls = []

    def rec(c):
        calls.append(os.path.exists(os.path.join(c["UPDATE_STATE_DIR"], "pending.json")))
        return {"result": "ok"}

    pend = {"slot": "b", "version": "2", "from": "a", "from_version": "1"}

    # trial boot, health fails: never synced, reboot requested
    root, conf, boot, fdir = make(be)
    uu.write_state(conf, "pending.json", pend)
    reboots = []
    with patched(uu, "sync_boot_recovery", rec), patched(uu, "health_ok", lambda c: False), \
            patched(uu, "be_reboot", lambda *a, **k: reboots.append(1)), \
            bsd(be):
        rc, out = uu.cmd_boot_ok(argparse.Namespace(), conf)
    check(f"{be}: trial boot with failing health never syncs the boot partition", calls == [] and rc == 2 and reboots == [1], (calls, rc, out))

    # trial boot, health ok: synced exactly once, after the confirmation (pending.json already gone)
    root, conf, boot, fdir = make(be)
    conf["UPDATE_HEALTH_TIMEOUT"] = "5"             # a health loop that is allowed to run (it returns at once)
    uu.write_state(conf, "pending.json", pend)
    with patched(uu, "sync_boot_recovery", rec), patched(uu, "health_ok", lambda c: True), \
            patched(uu, "be_reboot", lambda *a, **k: None), bsd(be):
        rc, out = uu.cmd_boot_ok(argparse.Namespace(), conf)
    check(f"{be}: trial boot with health ok syncs once, after confirm_now", calls == [False] and rc == 0 and out.get("confirmed"), (calls, rc, out))

    # trial that did not come back (pending slot is not the running one): never synced
    calls.clear()
    root, conf, boot, fdir = make(be)
    uu.write_state(conf, "pending.json", dict(pend, slot="a"))
    with patched(uu, "sync_boot_recovery", rec), patched(uu, "be_reboot", lambda *a, **k: None), bsd(be):
        rc, out = uu.cmd_boot_ok(argparse.Namespace(), conf)
    check(f"{be}: a trial that did not come back never syncs", calls == [] and out.get("rolled_back") is True, (calls, out))

    # plain boot of a confirmed slot: synced once
    calls.clear()
    root, conf, boot, fdir = make(be)
    with patched(uu, "sync_boot_recovery", rec), patched(uu, "be_reboot", lambda *a, **k: None):
        rc, out = uu.cmd_boot_ok(argparse.Namespace(), conf)
    check(f"{be}: plain boot syncs once", calls == [False] and rc == 0, (calls, rc, out))

    # manual confirm: synced once, after the confirmation
    calls.clear()
    root, conf, boot, fdir = make(be)
    uu.write_state(conf, "pending.json", pend)
    with patched(uu, "sync_boot_recovery", rec), patched(uu, "be_reboot", lambda *a, **k: None), bsd(be):
        rc, out = uu.cmd_confirm(argparse.Namespace(), conf)
    check(f"{be}: confirm syncs once, after confirm_now", calls == [False] and rc == 0 and out.get("confirmed"), (calls, rc, out))


def case_status_field():
    root, conf, boot, fdir = make("rpi", dtb=True)
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "UNITOTEM_UPDATE_CONF": os.path.join(root, "absent.conf")}
    for k in ("STATE_DIR", "RUN_DIR", "CMDLINE", "BOOTFS", "RECOVERY_DIR", "BACKEND", "HEALTH_URL", "DT_BOOTLOADER", "VERSION_FILE",
              "GRUBENV", "ESP_MOUNT", "DATA", "AUTOREPAIR"):
        env["UNITOTEM_UPDATE_" + k] = conf["UPDATE_" + k]
    p = subprocess.run([sys.executable, "-I", UU, "--json", "status"], env=env, capture_output=True, text=True, timeout=60)
    check("status: unitotem-update --json status runs with redirected paths", p.returncode == 0, p.stderr)
    out = json.loads(p.stdout) if p.returncode == 0 else {}
    check("status: key boot_recovery is present and null before any sync", "boot_recovery" in out and out["boot_recovery"] is None, out.get("boot_recovery"))
    r = sync(conf)
    p = subprocess.run([sys.executable, "-I", UU, "--json", "status"], env=env, capture_output=True, text=True, timeout=60)
    out = json.loads(p.stdout) if p.returncode == 0 else {}
    check("status: boot_recovery carries the last sync record", out.get("boot_recovery", {}).get("result") == r["result"] == "ok"
          and out["boot_recovery"]["to"] == NEW_LEVEL, out.get("boot_recovery"))


def case_pure():
    check("manifest: parses level and entries",
          uu.parse_recovery_manifest("# unitotem-recovery-level: 3\n" + "a" * 64 + "  vmlinuz\n" + "b" * 64 + "  initrd.img\n") == (3, [("vmlinuz", "a" * 64), ("initrd.img", "b" * 64)]))
    check("manifest: no level line is rejected", uu.parse_recovery_manifest("a" * 64 + "  vmlinuz\n" + "b" * 64 + "  initrd.img\n") is None)
    check("manifest: path traversal is rejected", uu.parse_recovery_manifest("# unitotem-recovery-level: 3\n" + "a" * 64 + "  ../x\n") is None)
    check("manifest: missing initrd is rejected", uu.parse_recovery_manifest("# unitotem-recovery-level: 3\n" + "a" * 64 + "  vmlinuz\n") is None)
    check("level: absent line is 0", uu.recovery_level("") == 0 and uu.recovery_level("# unitotem-recovery-level: 12\n") == 12)


def main():
    guard = Guard()
    with patched(uu, "subprocess", guard):
        for be in ("grub", "rpi"):
            case_equal_level_noop(be)
            case_lower_level_noop(be)
            case_corrupt_copy(be)
            case_image_mismatch(be)
            case_cut_between_renames(be)
            case_cut_before_sha(be)
            case_stray_new_removed(be)
            case_missing_manifest(be)
            case_low_space(be)
            call_sites(be)
        case_grub_dtb_refused()
        case_rpi_firmware_not_synced()
        case_rpi_device_files_untouched()
        case_status_field()
        case_pure()
    check("no mount, umount or reboot command was attempted", not Guard.refused, Guard.refused)
    for r in ROOTS:
        shutil.rmtree(r, ignore_errors=True)
    print(f"\n{ok} passed, {fail} failed")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())

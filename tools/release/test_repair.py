#!/usr/bin/env python3
"""Host-side test of the self-repair pieces of unitotem-update that need no block device: the Raspberry boot-file clone, the
failover guard bookkeeping, and the decision of when a repair runs. The partclone copy itself is proven on a VM/hardware.

  python3 tools/release/test_repair.py
"""
import importlib.machinery, importlib.util, io, os, struct, sys, tempfile, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "unitotem/files/unitotem-update"))
spec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(spec); loader.exec_module(uu)
REAL_SLOT_SOUND = uu.slot_sound                           # the section at the end needs the real check back

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
    open(bf + "/slota/cmdline.txt", "w").write("console=tty1 root=LABEL=ROOT_A rootwait ro quiet unitotem.slot=a video=HDMI-A-1:1920x1080@60D,panel_orientation=right_side_up\n")
    uu.rpi_clone_bootfiles(conf, "a", "b")
    check("clone: a video= orientation option travels to the new slot", "video=HDMI-A-1:1920x1080@60D,panel_orientation=right_side_up" in open(bf + "/slotb/cmdline.txt").read())
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
    uu.slot_sound = lambda c, s: (False, "empty")
    st = uu.slots_state(conf)
    st["b"] = {"version": None, "valid": False}; uu.write_state(conf, "slots.json", st)
    # No real disk may be found or written here: an empty sysfs and no blkid/findmnt (a host has real partitions).
    old_sys_env, old_run_out = os.environ.get("UNITOTEM_SYS_BLOCK"), uu.run_out
    os.environ["UNITOTEM_SYS_BLOCK"] = os.path.join(td, "no-sys-block"); os.makedirs(os.environ["UNITOTEM_SYS_BLOCK"])
    uu.run_out = lambda *cmd, check=True: ""
    try:
        uu.do_repair(argparse.Namespace(auto=True, force=False, foreground=True), conf); reached = False
    except uu.Fail as e:
        reached = e.code == "no-slot-device"          # it got as far as looking for the partitions: an unsound other slot is rebuilt
    finally:
        uu.run_out = old_run_out
        if old_sys_env is None: os.environ.pop("UNITOTEM_SYS_BLOCK", None)
        else: os.environ["UNITOTEM_SYS_BLOCK"] = old_sys_env
    check("auto: an unsound other slot (even one never valid, e.g. empty after a recovery) is rebuilt", reached)
    uu.slot_sound = lambda c, s: (True, "ok")
    st["b"] = {"version": "1", "valid": True, "prepared": True}; uu.write_state(conf, "slots.json", st)
    rc, out = uu.do_repair(argparse.Namespace(auto=True, force=False, foreground=True), conf)
    check("auto: a sound and prepared other slot is left alone", out.get("repaired") is False and "sound" in out.get("reason", ""), out)
    st["b"] = {"version": "1", "valid": True}; uu.write_state(conf, "slots.json", st)
    try:
        uu.do_repair(argparse.Namespace(auto=True, force=False, foreground=True), conf); unprep = False
    except uu.Fail as e:
        unprep = e.code == "no-slot-device"       # passes slot_sound but was never prepared: the repair goes on to the copy
    check("auto: a sound but unprepared other slot is repaired (cut before its state was written)", unprep)

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

# --- duplicate-label repair: superblock label and checksum, slot device lookup (fake sysfs and blkid, no devices)
def crc32c_ref(data):                                     # bit-by-bit reference, independent of the table in unitotem-update
    c = 0xFFFFFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    return c


def make_sb(label, csum):
    sb = bytearray(1024)
    struct.pack_into("<H", sb, 0x38, 0xEF53)
    sb[0x78:0x78 + len(label)] = label.encode()
    struct.pack_into("<I", sb, 0x64, 0x400 if csum else 0)
    if csum:
        sb[0x175] = 1
        struct.pack_into("<I", sb, 0x3FC, 0x12345678)
    return bytes(sb)


def raises(fn, exc):
    try:
        fn(); return False
    except exc:
        return True


check("crc32c: known answer (check value 0xE3069283 without final xor)", uu.crc32c_raw(0xFFFFFFFF, b"123456789") == 0x1CF96D7C)
check("crc32c: table matches the bitwise reference", uu.crc32c_raw(0xFFFFFFFF, bytes(range(256)) * 3) == crc32c_ref(bytes(range(256)) * 3))

sb = make_sb("ROOT_A", csum=True)
out = uu.patch_label(sb, "ROOT_B")
check("patch_label: label bytes replaced, zero padded", out[0x78:0x88] == b"ROOT_B" + bytes(10), out[0x78:0x88])
check("patch_label: the rest of the superblock unchanged", out[:0x78] == sb[:0x78] and out[0x88:0x3FC] == sb[0x88:0x3FC])
check("patch_label: checksum is crc32c of the first 1020 bytes", out[0x3FC:0x400] == struct.pack("<I", crc32c_ref(out[:0x3FC])))
check("patch_label: checksum changed with the label", out[0x3FC:0x400] != sb[0x3FC:0x400])
check("patch_label: the longest label (16) is kept", uu.patch_label(sb, "X" * 16)[0x78:0x88] == b"X" * 16)
sbn = make_sb("ROOT_A", csum=False)
outn = uu.patch_label(sbn, "ROOT_B")
check("patch_label: no metadata_csum, checksum field left alone", outn[0x3FC:0x400] == sbn[0x3FC:0x400] and outn[0x78:0x80] == b"ROOT_B\0\0")
check("patch_label: longer block than 1024 is cut to the superblock", uu.patch_label(sb + b"\xff" * 4096, "ROOT_B") == out)
check("patch_label: bad magic refused", raises(lambda: uu.patch_label(bytes(1024), "ROOT_B"), ValueError))
check("patch_label: 17-char label refused", raises(lambda: uu.patch_label(sb, "X" * 17), ValueError))
check("patch_label: NUL in label refused", raises(lambda: uu.patch_label(sb, "RO\0T"), ValueError))
check("patch_label: non-ASCII label refused", raises(lambda: uu.patch_label(sb, "ROÒT"), ValueError))
check("patch_label: short superblock refused", raises(lambda: uu.patch_label(sb[:512], "ROOT_B"), ValueError))
bad_type = bytearray(sb); bad_type[0x175] = 0
check("patch_label: checksum type other than crc32c refused", raises(lambda: uu.patch_label(bytes(bad_type), "ROOT_B"), ValueError))

# clone_into_slot on a regular file with a fake partclone stream (no device, no partclone binary)
MIB = 1 << 20
real_popen = uu.subprocess.Popen


class FakePopen:
    rc = 0
    stream = b""

    def __init__(self, cmd, stdin=None, stdout=None, stderr=None, **kw):
        self.stdout = io.BytesIO(FakePopen.stream); self.returncode = FakePopen.rc

    def wait(self, timeout=None): return self.returncode
    def poll(self): return self.returncode
    def kill(self): pass


def run_clone(dev_bytes, stream, rc=0):
    with tempfile.TemporaryDirectory() as td2:
        dev = os.path.join(td2, "part"); open(dev, "wb").write(dev_bytes)
        FakePopen.stream = stream; FakePopen.rc = rc
        uu.subprocess.Popen = FakePopen
        serr = tempfile.TemporaryFile()
        try:
            uu.clone_into_slot(dict(uu.CONF_DEFAULTS), io.BytesIO(b""), dev, "ROOT_B", serr)
            return None, open(dev, "rb").read()
        except uu.Fail as e:
            return e.code, None
        finally:
            uu.subprocess.Popen = real_popen


head = bytearray(MIB)
head[1024:2048] = make_sb("ROOT_A", csum=True)
head[0:4] = b"HEAD"; head[2048:2052] = b"TAIL"
stream = bytes(head) + b"\x01" * MIB + bytes(MIB) + b"\x02" * MIB
code, got = run_clone(b"\xaa" * (4 * MIB), stream)
check("clone: stream written, zero chunk overwrites old data", code is None and got is not None, code)
if got is not None:
    check("clone: head before the superblock written", got[0:1024] == bytes(head[0:1024]))
    check("clone: superblock carries the new label and a valid checksum",
          got[1024:2048] == uu.patch_label(bytes(head[1024:2048]), "ROOT_B") and got[1024 + 0x78:1024 + 0x80] == b"ROOT_B\0\0")
    check("clone: checksum matches the patched superblock", got[1024 + 0x3FC:1024 + 0x400] == struct.pack("<I", crc32c_ref(got[1024:1024 + 0x3FC])))
    check("clone: head after the superblock written", got[2048:MIB] == bytes(head[2048:MIB]))
    check("clone: data chunk written", got[MIB:2 * MIB] == b"\x01" * MIB)
    check("clone: zero chunks written as zeros", got[2 * MIB:3 * MIB] == bytes(MIB))
    check("clone: last chunk written", got[3 * MIB:] == b"\x02" * MIB)
code, _ = run_clone(b"\xaa" * (4 * MIB), stream[:MIB // 2])
check("clone: stream shorter than 1 MiB fails", code == "write-failed", code)
code, _ = run_clone(b"\xaa" * (2 * MIB), stream)
check("clone: image larger than the partition fails before writing", code == "write-failed", code)
code, _ = run_clone(b"\xaa" * (4 * MIB), stream, rc=1)
check("clone: partclone restore failure fails", code == "write-failed", code)

# slot_dev with a fake sysfs tree and a fake blkid/findmnt
SYS = tempfile.mkdtemp(prefix="agent-S-w1-sys-")
sysroot = os.path.join(SYS, "devices", "fake")
DISKS = {"mmcblk0": 4, "nvme0n1": 4}
for disk, n in DISKS.items():
    d = os.path.join(sysroot, disk); os.makedirs(d)
    os.symlink(d, os.path.join(SYS, disk))
    for i in range(1, n + 1):
        p = f"{disk}p{i}"; pd = os.path.join(d, p); os.makedirs(pd)
        open(os.path.join(pd, "partition"), "w").write(f"{i}\n")
        os.symlink(pd, os.path.join(SYS, p))

FS = {}          # device -> {"PARTLABEL": .., "LABEL": .., "TYPE": ..}
ROOT = ["/dev/mmcblk0p3"]
real_run_out = uu.run_out


def fake_run_out(*cmd, check=True):
    if cmd[0] == "findmnt":
        return ROOT[0]
    if cmd[0] == "blkid" and "-t" in cmd:
        tag, value = cmd[cmd.index("-t") + 1].split("=", 1)
        return "\n".join(d for d in sorted(FS) if FS[d].get(tag) == value)
    if cmd[0] == "blkid" and "-s" in cmd:
        return FS.get(cmd[-1], {}).get(cmd[cmd.index("-s") + 1], "")
    raise AssertionError(f"unexpected command {cmd}")


def slot(devs, root="/dev/mmcblk0p2"):             # the running root is slot A: the neighbour rule looks at slot B
    FS.clear(); FS.update(devs); ROOT[0] = root


old_sys = os.environ.get("UNITOTEM_SYS_BLOCK")
os.environ["UNITOTEM_SYS_BLOCK"] = SYS
uu.run_out = fake_run_out
try:
    slot({"/dev/mmcblk0p2": {"PARTLABEL": "ROOT_A", "LABEL": "ROOT_A", "TYPE": "ext4"},
          "/dev/mmcblk0p3": {"PARTLABEL": "ROOT_B", "LABEL": "ROOT_B", "TYPE": "ext4"}})
    check("slot_dev: PARTLABEL hit", uu.slot_dev("a") == "/dev/mmcblk0p2" and uu.slot_dev("b") == "/dev/mmcblk0p3")

    slot({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "ROOT_B", "TYPE": "ext4"}})
    check("slot_dev: single filesystem label (MBR)", uu.slot_dev("a") == "/dev/mmcblk0p2" and uu.slot_dev("b") == "/dev/mmcblk0p3")

    slot({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "ROOT_A", "TYPE": "ext4"}})
    check("slot_dev: two ROOT_A on the running disk -> lowest", uu.slot_dev("a") == "/dev/mmcblk0p2")

    slot({"/dev/mmcblk0p3": {"LABEL": "ROOT_B", "TYPE": "ext4"}, "/dev/mmcblk0p4": {"LABEL": "ROOT_B", "TYPE": "ext4"}},
         root="/dev/mmcblk0p2")
    check("slot_dev: two ROOT_B on the running disk -> highest", uu.slot_dev("b") == "/dev/mmcblk0p4")

    slot({"/dev/mmcblk0p3": {"LABEL": "ROOT_B", "TYPE": "ext4"}, "/dev/nvme0n1p3": {"LABEL": "ROOT_B", "TYPE": "ext4"}},
         root="/dev/mmcblk0p2")
    check("slot_dev: duplicate on another disk is ignored", uu.slot_dev("b") == "/dev/mmcblk0p3")

    slot({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "ROOT_NEW", "TYPE": "ext4"}})
    check("slot_dev: neutral label, neighbour rule, slot b (+1)", uu.slot_dev("b") == "/dev/mmcblk0p3")

    slot({"/dev/mmcblk0p2": {"LABEL": "", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "ROOT_B", "TYPE": "ext4"}},
         root="/dev/mmcblk0p3")
    check("slot_dev: blank label, neighbour rule, slot a (-1)", uu.slot_dev("a") == "/dev/mmcblk0p2")

    slot({"/dev/nvme0n1p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/nvme0n1p3": {"LABEL": "", "TYPE": "ext4"}},
         root="/dev/nvme0n1p2")
    check("slot_dev: nvme neighbour, slot b", uu.slot_dev("b") == "/dev/nvme0n1p3")

    slot({"/dev/nvme0n1p2": {"LABEL": "", "TYPE": "ext4"}, "/dev/nvme0n1p3": {"LABEL": "ROOT_B", "TYPE": "ext4"}},
         root="/dev/nvme0n1p3")
    check("slot_dev: nvme neighbour, slot a", uu.slot_dev("a") == "/dev/nvme0n1p2")

    for reserved in ("DATA", "FIRMWARE", "EFI", "BOOT"):
        slot({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": reserved, "TYPE": "ext4"}})
        check(f"slot_dev: neighbour labelled {reserved} refused", uu.slot_dev("b") == "")
    slot({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "", "TYPE": "vfat"}})
    check("slot_dev: neighbour with a non-ext4 filesystem refused", uu.slot_dev("b") == "")
    slot({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "", "TYPE": ""}})
    check("slot_dev: neighbour with no filesystem accepted", uu.slot_dev("b") == "/dev/mmcblk0p3")
    slot({"/dev/mmcblk0p4": {"LABEL": "ROOT_A", "TYPE": "ext4"}})
    check("slot_dev: neighbour partition missing on the disk", uu.slot_dev("b") == "")
    slot({"/dev/mmcblk0p1": {"LABEL": "ROOT_B", "TYPE": "ext4"}, "/dev/mmcblk0p2": {"LABEL": "", "TYPE": "ext4"}})
    check("slot_dev: neighbour below partition 1 is not looked up", uu.slot_dev("a") == "")
    slot({"/dev/mmcblk0p2": {"LABEL": "DATA", "TYPE": "ext4"}})
    check("slot_dev: nothing found, nothing returned", uu.slot_dev("a") == "" and uu.slot_dev("b") == "")
finally:
    uu.run_out = real_run_out
    if old_sys is None: os.environ.pop("UNITOTEM_SYS_BLOCK", None)
    else: os.environ["UNITOTEM_SYS_BLOCK"] = old_sys
    import shutil
    shutil.rmtree(SYS, ignore_errors=True)

# --- blank ROOT_B: created by the layout, never written (no label, no filesystem). Cause first-boot, repair clones into it.
import shutil, subprocess

uu.slot_sound = REAL_SLOT_SOUND


def make_sys(disks):
    base = tempfile.mkdtemp(prefix="agent-S-w1-blank-")
    sysroot = os.path.join(base, "devices", "fake")
    for disk, n in disks.items():
        d = os.path.join(sysroot, disk); os.makedirs(d)
        os.symlink(d, os.path.join(base, disk))
        for i in range(1, n + 1):
            pd = os.path.join(d, f"{disk}p{i}"); os.makedirs(pd)
            open(os.path.join(pd, "partition"), "w").write(f"{i}\n")
            os.symlink(pd, os.path.join(base, f"{disk}p{i}"))
    return base


class Quiet:                                              # stands in for io_friendly: no sysfs writes
    def __init__(self, *a): pass
    def apply(self): pass
    def restore(self): pass


def blank_run_out(*cmd, check=True):
    ver = blank_version[0]
    if cmd[0] == "findmnt":
        return ROOT[0]
    if cmd[0] == "blkid" and "-t" in cmd:
        tag, value = cmd[cmd.index("-t") + 1].split("=", 1)
        return "\n".join(d for d in sorted(FS) if FS[d].get(tag) == value)
    if cmd[0] == "blkid" and "-s" in cmd:
        return FS.get(cmd[-1], {}).get(cmd[cmd.index("-s") + 1], "")
    if cmd[0] in ("tune2fs", "e2fsck"):
        return ""
    if cmd[0] == "mount":                                 # the copy reports the running version
        d = os.path.join(cmd[-1], "usr/share/unitotem"); os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "release-version"), "w").write(ver + "\n")
        return ""
    raise AssertionError(f"unexpected command {cmd}")


blank_version = ["2026.11.54"]
ROOT = ["/dev/mmcblk0p2"]


def blank_case(name, devs, root, want_cause, want_dev):
    FS.clear(); FS.update(devs); ROOT[0] = root
    base = make_sys({"mmcblk0": 3})
    td3 = tempfile.mkdtemp(prefix="agent-S-w1-blank-state-")
    run = os.path.join(td3, "run"); os.makedirs(run)
    cmdline = os.path.join(td3, "cmdline"); open(cmdline, "w").write("root=LABEL=ROOT_A unitotem.slot=a\n")
    vf = os.path.join(td3, "release-version"); open(vf, "w").write(blank_version[0] + "\n")
    conf3 = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="grub", UPDATE_STATE_DIR=os.path.join(td3, "state"), UPDATE_RUN_DIR=run,
                 UPDATE_CMDLINE=cmdline, UPDATE_VERSION_FILE=vf, UPDATE_DATA=os.path.join(td3, "data"), UPDATE_HEALTH_URL="")
    calls = []

    def fake_clone(c, src, dev, new_label, serr):
        calls.append((dev, new_label)); src.read()

    def fake_run(cmd, **kw):                              # findmnt -S: not mounted; e2fsck -fy on the copy: clean
        if cmd[0] == "umount":                            # the fake mount left its files in the test's own temp dir
            shutil.rmtree(os.path.join(cmd[-1], "usr"), ignore_errors=True)   # the directory itself stays: do_repair removes it
        return subprocess.CompletedProcess(cmd, 1 if cmd[0] == "findmnt" else 0, b"", b"")

    FakePopen.rc, FakePopen.stream = 0, b""                # the source stream reads clean (the clone itself is faked)
    saved = (uu.run_out, uu.subprocess.run, uu.subprocess.Popen, uu.clone_into_slot, uu.prepare_overlays, uu.io_friendly)
    old_env = os.environ.get("UNITOTEM_SYS_BLOCK")
    os.environ["UNITOTEM_SYS_BLOCK"] = base
    uu.run_out, uu.subprocess.run, uu.subprocess.Popen = blank_run_out, fake_run, FakePopen
    uu.clone_into_slot, uu.prepare_overlays, uu.io_friendly = fake_clone, (lambda *a: 0), Quiet
    try:
        check(f"{name}: blank B is not sound, cause {want_cause}", uu.slot_sound(conf3, "b") == (False, want_cause),
              uu.slot_sound(conf3, "b"))
        rc, out = uu.do_repair(argparse.Namespace(auto=True, force=False, foreground=True), conf3)
        check(f"{name}: repair cloned into the blank slot", calls == [(want_dev, "ROOT_B")], calls)
        check(f"{name}: repair reports cause {want_cause}", out.get("repaired") is True and out.get("cause") == want_cause, out)
        check(f"{name}: event log names the cause", want_cause in open(uu.state_path(conf3, "events.log")).read())
        lr = uu.read_state(conf3, "last-result.json") or {}
        check(f"{name}: last-result is ok with the cause", lr.get("result") == "ok" and lr.get("cause") == want_cause, lr)
        st3 = uu.read_state(conf3, "slots.json", {}) or {}
        check(f"{name}: slot b marked valid after the copy", st3.get("b", {}).get("valid") is True, st3)
    finally:
        uu.run_out, uu.subprocess.run, uu.subprocess.Popen, uu.clone_into_slot, uu.prepare_overlays, uu.io_friendly = saved
        if old_env is None: os.environ.pop("UNITOTEM_SYS_BLOCK", None)
        else: os.environ["UNITOTEM_SYS_BLOCK"] = old_env
        shutil.rmtree(base, ignore_errors=True); shutil.rmtree(td3, ignore_errors=True)


blank_gpt = {"/dev/mmcblk0p2": {"PARTLABEL": "ROOT_A", "LABEL": "ROOT_A", "TYPE": "ext4"},
             "/dev/mmcblk0p3": {"PARTLABEL": "ROOT_B"}}
blank_case("GPT blank ROOT_B", blank_gpt, "/dev/mmcblk0p2", "first-boot", "/dev/mmcblk0p3")
blank_mbr = {"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "", "TYPE": ""}}
blank_case("MBR blank ROOT_B (neighbour)", blank_mbr, "/dev/mmcblk0p2", "first-boot", "/dev/mmcblk0p3")

# unprepared: slot_sound passes (B looks sound) but slots.json has no valid+prepared entry for B: the clone repeats, cause unprepared
FS.clear(); FS.update({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "ROOT_B", "TYPE": "ext4"}})
ROOT[0] = "/dev/mmcblk0p2"
base_u = make_sys({"mmcblk0": 3})
td5 = tempfile.mkdtemp(prefix="agent-S-w1-unprep-")
run5 = os.path.join(td5, "run"); os.makedirs(run5)
cmd5 = os.path.join(td5, "cmdline"); open(cmd5, "w").write("root=LABEL=ROOT_A unitotem.slot=a\n")
vf5 = os.path.join(td5, "release-version"); open(vf5, "w").write("2026.11.54\n")
conf5 = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="grub", UPDATE_STATE_DIR=os.path.join(td5, "state"), UPDATE_RUN_DIR=run5,
             UPDATE_CMDLINE=cmd5, UPDATE_VERSION_FILE=vf5, UPDATE_DATA=os.path.join(td5, "data"), UPDATE_HEALTH_URL="")
st5 = uu.slots_state(conf5); st5["b"] = {"version": "2026.11.54", "valid": False}; uu.write_state(conf5, "slots.json", st5)
calls5 = []
saved5 = (uu.run_out, uu.subprocess.run, uu.subprocess.Popen, uu.clone_into_slot, uu.prepare_overlays, uu.io_friendly, uu.slot_sound)
old_env5 = os.environ.get("UNITOTEM_SYS_BLOCK"); os.environ["UNITOTEM_SYS_BLOCK"] = base_u
FakePopen.rc, FakePopen.stream = 0, b""
def clone5(c, src, dev, new_label, serr):
    calls5.append((dev, new_label)); src.read()
def run5_fake(cmd, **kw):
    if cmd[0] == "umount":
        shutil.rmtree(os.path.join(cmd[-1], "usr"), ignore_errors=True)
    return subprocess.CompletedProcess(cmd, 1 if cmd[0] == "findmnt" else 0, b"", b"")
uu.run_out, uu.subprocess.run, uu.subprocess.Popen = blank_run_out, run5_fake, FakePopen
uu.clone_into_slot, uu.prepare_overlays, uu.io_friendly = clone5, (lambda *a: 0), Quiet
uu.slot_sound = lambda c, s: (True, "ok")                 # B looks sound on disk
try:
    rc5, out5 = uu.do_repair(argparse.Namespace(auto=True, force=False, foreground=True), conf5)
    check("unprepared: the clone repeats into B", calls5 == [("/dev/mmcblk0p3", "ROOT_B")], calls5)
    check("unprepared: cause unprepared", out5.get("repaired") is True and out5.get("cause") == "unprepared", out5)
finally:
    (uu.run_out, uu.subprocess.run, uu.subprocess.Popen, uu.clone_into_slot, uu.prepare_overlays, uu.io_friendly, uu.slot_sound) = saved5
    if old_env5 is None: os.environ.pop("UNITOTEM_SYS_BLOCK", None)
    else: os.environ["UNITOTEM_SYS_BLOCK"] = old_env5
    shutil.rmtree(base_u, ignore_errors=True); shutil.rmtree(td5, ignore_errors=True)
uu.slot_sound = REAL_SLOT_SOUND

FS.clear(); FS.update({"/dev/mmcblk0p2": {"LABEL": "ROOT_A", "TYPE": "ext4"}, "/dev/mmcblk0p3": {"LABEL": "ROOT_NEW", "TYPE": "ext4"}})
ROOT[0] = "/dev/mmcblk0p2"
base = make_sys({"mmcblk0": 3})
old_env = os.environ.get("UNITOTEM_SYS_BLOCK"); os.environ["UNITOTEM_SYS_BLOCK"] = base
saved_run_out = uu.run_out
uu.run_out = blank_run_out
try:
    cfg_b = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="grub")
    check("a foreign label on B keeps cause label (a filesystem is there, not first-boot)", uu.slot_sound(cfg_b, "b") == (False, "label"),
          uu.slot_sound(cfg_b, "b"))
finally:
    uu.run_out = saved_run_out
    if old_env is None: os.environ.pop("UNITOTEM_SYS_BLOCK", None)
    else: os.environ["UNITOTEM_SYS_BLOCK"] = old_env
    shutil.rmtree(base, ignore_errors=True)

# status with a blank B: no crash, the other slot has no version and no rollback
td4 = tempfile.mkdtemp(prefix="agent-S-w1-status-")
cmdl4 = os.path.join(td4, "cmdline"); open(cmdl4, "w").write("root=LABEL=ROOT_A unitotem.slot=a\n")
vf4 = os.path.join(td4, "release-version"); open(vf4, "w").write("2026.11.54\n")
conf4 = dict(uu.CONF_DEFAULTS, UPDATE_BACKEND="grub", UPDATE_STATE_DIR=os.path.join(td4, "state"), UPDATE_RUN_DIR=os.path.join(td4, "run"),
             UPDATE_CMDLINE=cmdl4, UPDATE_VERSION_FILE=vf4, UPDATE_DATA=os.path.join(td4, "data"), UPDATE_HEALTH_URL="",
             UPDATE_BOOTFS=os.path.join(td4, "fat"), UPDATE_GRUBENV=os.path.join(td4, "grubenv"))
os.makedirs(conf4["UPDATE_RUN_DIR"]); os.makedirs(conf4["UPDATE_STATE_DIR"])
saved_ov = uu.overlay_status
uu.overlay_status = lambda c: None                        # reads the live overlay state of this host
try:
    rc, out = uu.cmd_status(argparse.Namespace(), conf4)
    check("status: blank other slot reports no version", rc == 0 and out.get("slot") == "a" and out.get("other_version") is None, out)
    check("status: blank other slot has no rollback", out.get("rollback_available") is False, out)
except Exception as e:
    check("status: blank other slot does not raise", False, repr(e))
finally:
    uu.overlay_status = saved_ov
    shutil.rmtree(td4, ignore_errors=True)

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

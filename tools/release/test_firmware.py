#!/usr/bin/env python3
"""Tests of unitotem/files/unitotem-firmware (status and check), with no network and no device.

A fake Raspberry Pi archive is built in a temporary directory: a real gpg key (GNUPGHOME in the temp dir),
a clearsigned InRelease, a gzip Packages index and .deb files written with a small ar writer. http_get is
replaced by a fake that serves those bytes. Every path (boot FAT, run dir, DT, vcgencmd, updater, keyring)
is redirected to the temp dir through the UNITOTEM_FW_* variables. Nothing under /boot, /etc, /run or
/var is written; the mtime of /etc/unitotem/users.json and the unitotem-firmware files under /run and
/boot are checked before and after.

  python3 tools/release/test_firmware.py
"""
import contextlib, errno, fcntl, glob, gzip, importlib.util, importlib.machinery, io, json, os, shutil, struct
import subprocess, sys, tarfile, tempfile, time, urllib.request, hashlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SRC = os.path.join(ROOT, "unitotem", "files", "unitotem-firmware")
LOADER = importlib.machinery.SourceFileLoader("unitotem_firmware", SRC)
SPEC = importlib.util.spec_from_loader("unitotem_firmware", LOADER)
F = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(F)

OK = FAIL = 0
LAST_NET = None
BASE = F.DEFAULTS["UNITOTEM_FW_BASE_URL"]
FW_VER, EE_VER = "1:1.20260915-1", "28.36-1"
FW_FN = "pool/main/r/raspi-firmware/raspi-firmware_1.20260915-1_all.deb"
EE_FN = "pool/main/r/rpi-eeprom/rpi-eeprom_28.36-1_all.deb"
TS_OLD, TS_NEW = 1780000000, 1793402435          # 2026-05-28, 2026-10-30
MODEL_PI4 = "Raspberry Pi 4 Model B Rev 1.5"
FW_CONTENT = {n: f"firmware {n} 2026-09".encode() * 7 for n in F.FW_NAMES}


def check(name, cond, extra=""):
    global OK, FAIL
    if cond:
        OK += 1; print("PASS:", name)
    else:
        FAIL += 1; print("FAIL:", name, extra)


def expect_fail(name, code, fn):
    try:
        fn()
    except F.Fail as e:
        check(name, e.code == code, f"expected {code}, got {e.code}: {e}")
        return e
    check(name, False, f"expected {code}, no refusal")
    return None


# ---------- gpg, archives ----------

def gpg(home, *args):
    cmd = ["gpg", "--homedir", home, "--batch", "--no-tty", "--pinentry-mode", "loopback", "--passphrase", ""]
    return subprocess.run(cmd + list(args), check=True, capture_output=True).stdout


def new_key(home):
    os.makedirs(home, mode=0o700, exist_ok=True)
    gpg(home, "--quick-gen-key", "UniTotem Test <test@unitotem.invalid>", "ed25519", "sign", "0")
    out = gpg(home, "--with-colons", "--list-keys").decode()
    return next(l.split(":")[9] for l in out.splitlines() if l.startswith("fpr:"))


def clearsign(home, fpr, text):
    d = tempfile.mkdtemp(prefix="fw-sign-")
    try:
        src, dst = os.path.join(d, "plain"), os.path.join(d, "InRelease")
        with open(src, "wb") as f:
            f.write(text)
        gpg(home, "-u", fpr, "--clearsign", "--yes", "-o", dst, src)
        with open(dst, "rb") as f:
            return f.read()
    finally:
        shutil.rmtree(d, ignore_errors=True)


def tar_gz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for name, kind, payload in entries:
            ti = tarfile.TarInfo(name)
            if kind == "dir":
                ti.type = tarfile.DIRTYPE; ti.mode = 0o755; t.addfile(ti)
            elif kind == "sym":
                ti.type = tarfile.SYMTYPE; ti.linkname = payload; t.addfile(ti)
            else:
                ti.size = len(payload); ti.mode = 0o644; t.addfile(ti, io.BytesIO(payload))
    return buf.getvalue()


def ar_bytes(members):
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        out += (name.ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6) + "100644".ljust(8)
                + str(len(data)).ljust(10)).encode() + b"`\n" + data
        if len(data) & 1:
            out += b"\n"
    return bytes(out)


def deb(data_entries):
    return ar_bytes([("debian-binary", b"2.0\n"),
                     ("control.tar.gz", tar_gz([("./control", "file", b"Package: x\n")])),
                     ("data.tar.gz", tar_gz(data_entries))])


def default_fw(content=None):
    content = content or FW_CONTENT
    ents = [("./usr/share/doc/raspi-firmware/copyright", "file", b"licence")]
    ents += [(f"./usr/lib/raspi-firmware/{n}", "file", content[n]) for n in F.FW_NAMES]
    return ents


def image(size, ts):
    return f"BUILD_TIMESTAMP={ts}\n".encode().ljust(size, b"\0")


# Test double of rpi-eeprom-config. It logs its argv (FW_TEST_ARGV_LOG), prints the running config
# (FW_TEST_CUR_CONFIG) and embeds the config after a BOOTCONF marker at 0x20000 of the image.
FAKE_TOOL = r'''#!/usr/bin/python3
import json, os, sys
VALUED = ("--config", "--timestamp", "--out", "--digest", "--pubkey")
args = sys.argv[1:]
log = os.environ.get("FW_TEST_ARGV_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps(args) + "\n")
opts, pos, i = {}, [], 0
while i < len(args):
    if args[i] in VALUED:
        opts[args[i]] = args[i + 1]; i += 2
    else:
        pos.append(args[i]); i += 1
MARK = 0x20000
def emit(data):
    if "--out" in opts:
        open(opts["--out"], "wb").write(data)
    else:
        sys.stdout.buffer.write(data)
if not pos:
    emit(open(os.environ["FW_TEST_CUR_CONFIG"], "rb").read())
elif "--timestamp" not in opts and "--config" not in opts:
    img = open(pos[0], "rb").read()
    start = img.find(b"BOOTCONF", MARK, MARK + 4096)
    emit(img[start + 8:img.find(b"\0", start)] if start >= 0 else b"")
else:
    img = bytearray(open(pos[0], "rb").read())
    if "--config" in opts:
        cfg = open(opts["--config"], "rb").read()
        img[MARK:MARK + 4096] = (b"BOOTCONF" + cfg + b"\0").ljust(4096, b"\0")
    open(opts["--out"], "wb").write(bytes(img))
'''.encode()


def default_ee(family, ts=TS_NEW):
    d = f"./usr/lib/firmware/raspberrypi/{F.EE_DIR[family]}/default/"
    ents = [(d + "pieeprom-2026-09-23.bin", "file", image(F.EE_SIZE[family], TS_OLD)),
            (d + "pieeprom-2026-10-30.bin", "file", image(F.EE_SIZE[family], ts)),
            (d + "recovery.bin", "file", b"R" * 100),
            ("./usr/bin/rpi-eeprom-config", "file", FAKE_TOOL),
            (f"./usr/lib/firmware/raspberrypi/{F.EE_DIR[family]}/critical", "sym", "default")]
    if family == "pi4":
        ents.append((d + "vl805-000138c0.bin", "file", b"V" * 100))
    return ents


class Repo:
    """Signed fake archive. routes maps the https URL to the bytes served."""
    def __init__(self, gh, fpr, fw_entries=None, ee_entries=None, fw_deb=None, ee_deb=None, text_fn=None):
        self.fw_deb = fw_deb or deb(fw_entries or default_fw())
        self.ee_deb = ee_deb or deb(ee_entries or default_ee("pi4"))
        stanzas = [stanza("raspi-firmware", FW_VER, FW_FN, self.fw_deb),
                   stanza("rpi-eeprom", EE_VER, EE_FN, self.ee_deb),
                   stanza("bluez-firmware", "1.2-13", "pool/main/b/bluez/bluez_1.2-13_all.deb", b"x")]
        text = "\n".join(stanzas)
        if text_fn:
            text = text_fn(text)
        self.packages_gz = gzip.compress(text.encode())
        release = ("Origin: Raspberry Pi Foundation\nSuite: stable\nCodename: trixie\nArchitectures: arm64\n"
                   "Components: main\nSHA256:\n"
                   f" {hashlib.sha256(self.packages_gz).hexdigest()} {len(self.packages_gz)} "
                   "main/binary-arm64/Packages.gz\n").encode()
        self.inrelease = clearsign(gh, fpr, release)
        self.routes = {f"{BASE}/dists/trixie/InRelease": self.inrelease,
                       f"{BASE}/dists/trixie/main/binary-arm64/Packages.gz": self.packages_gz,
                       f"{BASE}/{FW_FN}": self.fw_deb, f"{BASE}/{EE_FN}": self.ee_deb}


def stanza(pkg, ver, fn, data):
    return (f"Package: {pkg}\nVersion: {ver}\nArchitecture: all\nFilename: {fn}\n"
            f"Size: {len(data)}\nSHA256: {hashlib.sha256(data).hexdigest()}\nDescription: test\n")


class FakeNet:
    def __init__(self, routes):
        self.routes = dict(routes); self.calls = []

    def __call__(self, url, max_bytes, timeout=60):
        self.calls.append(url)
        F.require_https(url)
        if url not in self.routes:
            raise F.Fail("network", "not served")
        body = self.routes[url]
        if len(body) > max_bytes:
            raise F.Fail("too-large", "download exceeds its size limit")
        return body


@contextlib.contextmanager
def fake_net(net):
    old = F.http_get
    F.http_get = net
    try:
        yield net
    finally:
        F.http_get = old


@contextlib.contextmanager
def env(**kw):
    keys = {"UNITOTEM_FW_" + k.upper(): str(v) for k, v in kw.items()}
    old = {k: os.environ.get(k) for k in keys}
    os.environ.update(keys)
    try:
        yield
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def script(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)
    return path


class Lab:
    """One device: temp dirs and the mocked tools. env() is the UNITOTEM_FW_* set for the functions."""
    def __init__(self, td, model=MODEL_PI4, throttled="0x0", pending=None, updater_absent=False,
                 installed_ts=None, keyring=None):
        self.td = td
        self.boot, self.run, self.state = (os.path.join(td, x) for x in ("boot", "run", "state"))
        for d in (self.boot, self.run, self.state):
            os.makedirs(d, exist_ok=True)
        dt = os.path.join(td, "dt")
        os.makedirs(os.path.join(dt, "chosen", "bootloader"), exist_ok=True)
        with open(os.path.join(dt, "model"), "wb") as f:
            f.write((model or "").encode() + b"\0" if model is not None else b"")
        if model is None:
            os.remove(os.path.join(dt, "model"))
        if installed_ts is not None:
            with open(os.path.join(dt, "chosen", "bootloader", "build-timestamp"), "wb") as f:
                f.write(struct.pack(">I", installed_ts))
        self.dt = dt
        self.vc = script(os.path.join(td, "vcgencmd"),
                         f'case "$1" in\n  get_throttled) echo "throttled={throttled}" ;;\n'
                         f'  bootloader_version) printf "Oct 30 2026 12:00:00\\nversion x\\n" ;;\n  *) exit 1 ;;\nesac\n')
        if updater_absent:
            self.upd = os.path.join(td, "no-such-updater")
        else:
            self.upd = script(os.path.join(td, "unitotem-update"),
                              f"echo '{{\"pending_confirm\": {'true' if pending else 'false'}}}'\n")
        self.osrel = os.path.join(td, "os-release")
        with open(self.osrel, "w") as f:
            f.write("PRETTY_NAME=\"Debian\"\nVERSION_CODENAME=trixie\n")
        self.keyring = keyring or os.path.join(td, "no-keyring.gpg")

    def env(self):
        return dict(BOOT=self.boot, RUN=self.run, STATE=self.state, DT=self.dt, KEYRING=self.keyring,
                    VCGENCMD=self.vc, UPDATE=self.upd, EEPROM_CONF=os.path.join(self.td, "no-eeprom-conf"),
                    OS_RELEASE=self.osrel, APT_SOURCES=os.path.join(self.td, "no-sources"))

    def fat(self, files):
        for name, data in files.items():
            with open(os.path.join(self.boot, name), "wb") as f:
                f.write(data)


def fat_same():
    return {n: FW_CONTENT[n] for n in F.FW_NAMES}


def snapshot():
    paths = ["/etc/unitotem/users.json"]
    out = {}
    for p in paths:
        try:
            out[p] = os.stat(p).st_mtime_ns
        except OSError:
            out[p] = None
    out["run"] = sorted(glob.glob("/run/unitotem-firmware*"))
    out["boot"] = sorted(glob.glob("/boot/firmware/unitotem-firmware*"))
    return out


# ---------- tests ----------

def test_model_and_pairs(lab_dir):
    cases = {"Raspberry Pi 3 Model B Plus Rev 1.3": ("pi", "pi3"),
             "Raspberry Pi 3 Model B Rev 1.2": ("pi", "pi3"),
             "Raspberry Pi Zero 2 W Rev 1.0": ("pi", "pi3"),
             "Raspberry Pi 4 Model B Rev 1.5": ("pi", "pi4"),
             "Raspberry Pi Compute Module 4 Rev 1.1": ("pi", "pi4"),
             "Raspberry Pi 400 Rev 1.0": ("pi", "pi4"),
             "Raspberry Pi 5 Model B Rev 1.0": ("pi", "pi5"),
             "Raspberry Pi Zero W Rev 1.1": ("none", None),
             "Intel(R) Core(TM) i5 NUC": ("none", None),
             "": ("none", None)}
    for model, want in cases.items():
        check(f"classify {model or 'empty'!r}", F.classify(model or None) == want, str(F.classify(model)))
    lab = Lab(os.path.join(lab_dir, "model"), model="Intel NUC")
    with env(**lab.env()):
        got = F.cmd_status(F.conf())
    check("non-Pi model -> kind none", got == (0, {"kind": "none", "supported": False}), str(got))
    lab = Lab(os.path.join(lab_dir, "nomodel"), model=None)
    with env(**lab.env()):
        check("no device-tree model -> kind none", F.cmd_status(F.conf())[1] == {"kind": "none", "supported": False})
    lab = Lab(os.path.join(lab_dir, "pairs"), model=MODEL_PI4)
    lab.fat({"start4.elf": b"x"})
    check("start4.elf without fixup4.dat is not a pair", F.pairs_present(lab.boot) == [])
    lab.fat({"fixup4.dat": b"y", "start.elf": b"z", "fixup.dat": b"w", "bootcode.bin": b"b"})
    check("pairs: start4.elf and fixup4.dat both present -> pair",
          F.pairs_present(lab.boot) == ["start.elf+fixup.dat", "start4.elf+fixup4.dat"], str(F.pairs_present(lab.boot)))
    os.remove(os.path.join(lab.boot, "fixup4.dat"))
    check("pairs: start.elf+fixup.dat listed, start4.elf without fixup4.dat not yet",
          F.pairs_present(lab.boot) == ["start.elf+fixup.dat"], str(F.pairs_present(lab.boot)))
    lab.fat({"start4.elf": b"x", "fixup4.dat": b"y", "start4x.elf": b"q"})
    check("pairs: start4.elf+fixup4.dat present, bootcode.bin not a pair",
          F.pairs_present(lab.boot) == ["start.elf+fixup.dat", "start4.elf+fixup4.dat"],
          str(F.pairs_present(lab.boot)))


def test_status_device(lab_dir):
    lab = Lab(os.path.join(lab_dir, "pi3"), model="Raspberry Pi 3 Model B Plus Rev 1.3")
    with env(**lab.env()):
        _, out = F.cmd_status(F.conf())
    check("Pi 3: eeprom is null", out["family"] == "pi3" and out["eeprom"] is None, str(out))
    check("Pi 3: blockers empty on a clean device", out["blockers"] == [], str(out["blockers"]))
    lab = Lab(os.path.join(lab_dir, "pi4"), model=MODEL_PI4, installed_ts=TS_OLD)
    with open(os.path.join(lab.boot, "pieeprom.upd"), "wb") as f:
        f.write(b"x")
    with env(**lab.env()):
        _, out = F.cmd_status(F.conf())
    check("Pi 4: eeprom row present", isinstance(out["eeprom"], dict), str(out))
    check("Pi 4: installed date from device-tree", out["eeprom"]["installed"] == F.iso_date(TS_OLD), str(out["eeprom"]))
    check("Pi 4: pending from pieeprom.upd", out["eeprom"]["pending"] is True and out["reboot_required"] is True)
    check("Pi 4: channel default", out["eeprom"]["channel"] == "default")
    check("Pi 4: no check yet -> available/update null",
          out["files"]["available"] is None and out["files"]["update"] is None and out["checked_at"] is None)
    lab.fat({"start4.elf": b"a", "fixup4.dat": b"b", "start4x.elf.bak": b"c"})
    with env(**lab.env()):
        _, out = F.cmd_status(F.conf())
    check("status: bak detected", out["files"]["bak"] is True and out["files"]["pairs"] == ["start4.elf+fixup4.dat"])


def test_blockers(lab_dir):
    for thr, want in (("0x1", True), ("0x50005", True), ("0x0", False), ("0x50000", False)):
        lab = Lab(os.path.join(lab_dir, "uv" + thr), throttled=thr)
        with env(**lab.env()):
            _, out = F.cmd_status(F.conf())
        check(f"under-voltage blocker for throttled {thr} = {want}",
              ("under-voltage" in out["blockers"]) == want and out["under_voltage"] == want, str(out["blockers"]))
    lab = Lab(os.path.join(lab_dir, "pend"), pending=True)
    with env(**lab.env()):
        _, out = F.cmd_status(F.conf())
    check("pending-confirm blocker with updater reporting true", "pending-confirm" in out["blockers"], str(out))
    lab = Lab(os.path.join(lab_dir, "nopend"), pending=False)
    with env(**lab.env()):
        _, out = F.cmd_status(F.conf())
    check("pending-confirm false: no blocker", "pending-confirm" not in out["blockers"])
    lab = Lab(os.path.join(lab_dir, "noupd"), updater_absent=True)
    with env(**lab.env()):
        _, out = F.cmd_status(F.conf())
    check("updater absent: not a blocker", out["blockers"] == [], str(out["blockers"]))
    lab = Lab(os.path.join(lab_dir, "ro"))
    orig = F.fs_writable
    F.fs_writable = lambda path: False
    try:
        with env(**lab.env()):
            _, out = F.cmd_status(F.conf())
    finally:
        F.fs_writable = orig
    check("not-writable blocker", "not-writable" in out["blockers"], str(out["blockers"]))
    lab = Lab(os.path.join(lab_dir, "busy"))
    with open(os.path.join(lab.run, "unitotem-firmware.lock"), "a+") as lf:
        import fcntl
        fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with env(**lab.env()):
            _, out = F.cmd_status(F.conf())
    check("busy blocker while the lock is held", "busy" in out["blockers"] and out["op"] is None, str(out))
    with open(os.path.join(lab.run, "unitotem-firmware.progress"), "w") as f:
        json.dump({"op": "check", "phase": "fetch", "percent": 10, "state": "running", "error": None,
                   "reboot_required": False}, f)
    with env(**lab.env()):
        _, out = F.cmd_status(F.conf())
    check("stale progress without lock: op null", out["op"] is None and "busy" not in out["blockers"], str(out))


def test_check(lab_dir, gh, fpr, keyring):
    def lab_for(name, **kw):
        lab = Lab(os.path.join(lab_dir, name), keyring=keyring, **kw)
        return lab

    # update false: the FAT holds the package files
    lab = lab_for("same", installed_ts=TS_NEW)
    lab.fat(fat_same())
    repo = Repo(gh, fpr)
    with fake_net(FakeNet(repo.routes)) as net, env(**lab.env()):
        try:
            rc, out = F.cmd_check(F.conf())
        except F.Fail as e:
            rc, out = None, {"error": str(e)}
    check("check (identical FAT): rc 10 nothing to do", rc == 10, str(out))
    check("check: firmware update false", out.get("files", {}).get("update") is False, str(out))
    check("check: available is the package version", out.get("files", {}).get("available") == FW_VER)
    check("check: eeprom row with date", out.get("eeprom", {}).get("available") == F.iso_date(TS_NEW), str(out))
    check("check: Pi 4 fetched rpi-eeprom", f"{BASE}/{EE_FN}" in net.calls)
    check("check: cache written in run dir", os.path.isfile(os.path.join(lab.run, "unitotem-firmware.check.json")))
    with open(os.path.join(lab.run, "unitotem-firmware.check.json")) as f:
        cache = json.load(f)
    names = [x["name"] for x in cache["firmware"]["files"]]
    check("cache: per-file table has the 17 names only", names == list(F.FW_NAMES), str(names))
    check("cache: no path stored", all("/" not in x["name"] for x in cache["firmware"]["files"]))
    check("cache: eeprom holds the pieeprom and recovery", sorted(x["name"] for x in cache["eeprom"]["files"])
          == ["pieeprom-2026-10-30.bin", "recovery.bin", "vl805-000138c0.bin"], str(cache["eeprom"]))
    check("cache: eeprom build timestamp", cache["eeprom"]["build_timestamp"] == TS_NEW)
    with env(**lab.env()):
        _, st = F.cmd_status(F.conf())
    check("status after check: update false, checked_at set",
          st["files"]["update"] is False and st["checked_at"] is not None and st["eeprom"]["update"] is False, str(st))
    with open(os.path.join(lab.run, "unitotem-firmware.progress")) as f:
        prog = json.load(f)
    check("progress: done", prog["state"] == "done" and prog["error"] is None, str(prog))

    # update true: start4.elf on the FAT is old; EEPROM older than the image
    lab = lab_for("newer", installed_ts=TS_OLD)
    files = fat_same()
    files["start4.elf"] = b"old start4"
    lab.fat(files)
    with fake_net(FakeNet(repo.routes)), env(**lab.env()):
        rc, out = F.cmd_check(F.conf())
    check("check (old start4.elf): rc 0 update available", rc == 0 and out["files"]["update"] is True, str(out))
    check("check: eeprom update true when older than image", out["eeprom"]["update"] is True, str(out["eeprom"]))

    # Pi 3: no EEPROM row, no rpi-eeprom request
    lab = lab_for("pi3", model="Raspberry Pi 3 Model B Plus Rev 1.3")
    lab.fat(fat_same())
    with fake_net(FakeNet(repo.routes)) as net, env(**lab.env()):
        rc, out = F.cmd_check(F.conf())
    check("Pi 3 check: eeprom null", out["eeprom"] is None, str(out))
    check("Pi 3 check: rpi-eeprom not requested", f"{BASE}/{EE_FN}" not in net.calls, str(net.calls))

    # non-Pi: refused before any request
    lab = lab_for("pc", model="Intel NUC")
    with fake_net(FakeNet(repo.routes)) as net, env(**lab.env()):
        expect_fail("check on a non-Pi is refused", "unsupported", lambda: F.cmd_check(F.conf()))
    check("non-Pi check: no request made", net.calls == [])

    # failed check writes the failed progress state with the error code
    lab = lab_for("failed")
    with fake_net(FakeNet({})), env(**lab.env()):
        expect_fail("network failure reported", "network", lambda: F.cmd_check(F.conf()))
    with open(os.path.join(lab.run, "unitotem-firmware.progress")) as f:
        prog = json.load(f)
    check("failed check: progress state failed with error_code",
          prog["state"] == "failed" and prog["error"]["error_code"] == "network", str(prog))
    with env(**lab.env()):
        _, st = F.cmd_status(F.conf())
    check("status shows the last failure", st["error"] and st["error"]["error_code"] == "network", str(st["error"]))

    # busy: a held lock refuses the check (exit 12)
    lab = lab_for("busy")
    import fcntl
    with open(os.path.join(lab.run, "unitotem-firmware.lock"), "a+") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with fake_net(FakeNet(repo.routes)) as net, env(**lab.env()):
            e = expect_fail("check refused while busy", "busy", lambda: F.cmd_check(F.conf()))
    check("busy: rc 12", e is not None and e.rc == 12)
    check("busy: no request made", net.calls == [])


def test_refusals(lab_dir, gh, fpr, keyring):
    def run_check(repo, name, **kw):
        lab = Lab(os.path.join(lab_dir, name), keyring=keyring, installed_ts=TS_NEW, **kw)
        lab.fat(fat_same())
        net = FakeNet(repo.routes)
        with fake_net(net), env(**lab.env()):
            return F.cmd_check(F.conf()), net

    # forged signature: text changed after signing
    repo = Repo(gh, fpr)
    repo.routes[f"{BASE}/dists/trixie/InRelease"] = repo.inrelease.replace(b"Suite: stable", b"Suite: stablX")
    expect_fail("tampered InRelease refused", "bad-signature", lambda: run_check(repo, "forged1"))

    # forged signature: signed by a key that is not in the image keyring
    gh2 = os.path.join(os.path.dirname(lab_dir), "gh2")
    fpr2 = new_key(gh2)
    repo2 = Repo(gh2, fpr2)
    repo2.routes[f"{BASE}/dists/trixie/InRelease"] = repo2.inrelease
    expect_fail("InRelease signed by an unknown key refused", "bad-signature", lambda: run_check(repo2, "forged2"))

    # Packages hash mismatch
    repo = Repo(gh, fpr)
    pk = bytearray(repo.routes[f"{BASE}/dists/trixie/main/binary-arm64/Packages.gz"])
    pk[-1] ^= 0x01
    repo.routes[f"{BASE}/dists/trixie/main/binary-arm64/Packages.gz"] = bytes(pk)
    expect_fail("Packages hash mismatch refused", "hash-mismatch", lambda: run_check(repo, "pkhash"))

    # .deb hash mismatch: same size, different bytes
    repo = Repo(gh, fpr)
    bad = bytearray(repo.fw_deb)
    bad[-3] ^= 0xFF
    repo.routes[f"{BASE}/{FW_FN}"] = bytes(bad)
    expect_fail(".deb hash mismatch refused", "hash-mismatch", lambda: run_check(repo, "debhash"))

    # .deb size over the cap: refused from Packages, before any download
    repo = Repo(gh, fpr)
    old_caps = dict(F.PACKAGE_CAPS)
    F.PACKAGE_CAPS["raspi-firmware"] = len(repo.fw_deb) - 1
    try:
        expect_fail(".deb size over the cap refused (Packages Size)", "too-large",
                    lambda: run_check(repo, "capsize"))
    finally:
        F.PACKAGE_CAPS.clear(); F.PACKAGE_CAPS.update(old_caps)
    # served bytes over the cap while Packages claims a small size
    repo = Repo(gh, fpr)
    repo.routes[f"{BASE}/{FW_FN}"] = repo.fw_deb + b"\0" * (70 << 20)
    expect_fail(".deb served over the cap refused", "too-large", lambda: run_check(repo, "capserve"))

    # member traversal, absolute member, symlink member
    for name, ents in (
            ("traverse", default_fw() + [("./usr/lib/raspi-firmware/../../../etc/x", "file", b"x")]),
            ("absolute", default_fw() + [("/etc/x", "file", b"x")]),
            ("symlink", [e for e in default_fw() if not e[0].endswith("start4.elf")]
             + [("./usr/lib/raspi-firmware/start4.elf", "sym", "/etc/passwd")])):
        repo = Repo(gh, fpr, fw_entries=ents)
        expect_fail(f"member {name} refused", "unsafe-member", lambda: run_check(repo, "m-" + name))

    # missing wanted member
    repo = Repo(gh, fpr, fw_entries=[e for e in default_fw() if not e[0].endswith("fixup4x.dat")])
    expect_fail("missing wanted member refused", "bad-package", lambda: run_check(repo, "missing"))

    # member larger than the member cap
    repo = Repo(gh, fpr)
    old_cap = F.MEMBER_CAP
    F.MEMBER_CAP = 100
    try:
        expect_fail("member over the extraction cap refused", "too-large", lambda: run_check(repo, "memcap"))
    finally:
        F.MEMBER_CAP = old_cap

    # Filename and Version validation
    repo = Repo(gh, fpr, text_fn=lambda t: t.replace(f"Filename: {FW_FN}", "Filename: /pool/x.deb"))
    expect_fail("absolute Filename refused", "unsafe-filename", lambda: run_check(repo, "absfn"))
    repo = Repo(gh, fpr, text_fn=lambda t: t.replace(f"Filename: {FW_FN}", "Filename: pool/../../x.deb"))
    expect_fail("Filename with .. refused", "unsafe-filename", lambda: run_check(repo, "dotfn"))
    repo = Repo(gh, fpr, text_fn=lambda t: t.replace(f"Version: {FW_VER}", "Version: 1.0 bad"))
    expect_fail("bad Version refused", "bad-version", lambda: run_check(repo, "badver"))

    # http:// refused: the base URL, the fetch helper and a redirect to http
    lab = Lab(os.path.join(lab_dir, "http"), keyring=keyring, installed_ts=TS_NEW)
    net = FakeNet({})
    with fake_net(net), env(**lab.env(), BASE_URL="http://archive.raspberrypi.com/debian"):
        expect_fail("check with an http base URL refused", "insecure-url", lambda: F.cmd_check(F.conf()))
    check("http base: no request made", net.calls == [])
    expect_fail("http_get refuses http://", "insecure-url", lambda: F.http_get("http://example.invalid/x", 10))
    req = urllib.request.Request("https://example.invalid/a")
    expect_fail("redirect to http:// refused", "insecure-url",
                lambda: F._NoDowngrade().redirect_request(req, None, 302, "Found", {}, "http://example.invalid/b"))


def test_eeprom_and_status_after(lab_dir, gh, fpr, keyring):
    repo = Repo(gh, fpr, ee_entries=default_ee("pi5", ts=TS_NEW))
    lab = Lab(os.path.join(lab_dir, "pi5"), model="Raspberry Pi 5 Model B Rev 1.0", keyring=keyring,
              installed_ts=TS_NEW)
    lab.fat(fat_same())
    with fake_net(FakeNet(repo.routes)), env(**lab.env()):
        rc, out = F.cmd_check(F.conf())
    check("Pi 5 check: eeprom row, pieeprom picked from bootloader-2712", out["eeprom"]["available"] == F.iso_date(TS_NEW)
          and rc == 10, str(out))
    # apply-like stage: the FAT changes, status compares the cache with the live FAT
    lab.fat({"start4.elf": b"changed"})
    with env(**lab.env()):
        _, st = F.cmd_status(F.conf())
    check("status: files.update is the cached value (not recomputed)", st["files"]["update"] is False, str(st["files"]))


def test_main_json(lab_dir):
    lab = Lab(os.path.join(lab_dir, "json"), model="Intel NUC")
    buf = io.StringIO()
    with env(**lab.env()), contextlib.redirect_stdout(buf):
        rc = F.main(["--json", "status"])
    last = buf.getvalue().strip().splitlines()[-1]
    check("main: status prints one JSON object on the last line", rc == 0 and json.loads(last) == {"kind": "none", "supported": False})


# ---------- apply ----------

@contextlib.contextmanager
def raw_env(values):
    old = {k: os.environ.get(k) for k in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


@contextlib.contextmanager
def fake_start(calls):
    old = F.start_detached
    F.start_detached = lambda argv: calls.append(list(argv))
    try:
        yield calls
    finally:
        F.start_detached = old


def run_main(argv, lab, routes=None):
    """main() under the lab environment; returns (rc, last JSON line)."""
    global LAST_NET
    buf = io.StringIO()
    LAST_NET = FakeNet(routes or {})
    with fake_net(LAST_NET), env(**lab.env()), contextlib.redirect_stdout(buf):
        rc = F.main(argv)
    return rc, json.loads(buf.getvalue().strip().splitlines()[-1])


def fat_state(boot):
    """Every regular file on the FAT, by name, with its bytes."""
    out = {}
    for n in sorted(os.listdir(boot)):
        p = os.path.join(boot, n)
        if os.path.isfile(p):
            with open(p, "rb") as f:
                out[n] = f.read()
    return out


def old_fat():
    """An older release on the FAT, plus a user file that must never be touched."""
    return {"start.elf": b"old start", "fixup.dat": b"old fixup", "start4.elf": b"old start4",
            "fixup4.dat": b"old fixup4", "bootcode.bin": b"old bootcode", "config.txt": b"hdmi_group=2\n"}


def write_cache(lab, firmware_update, eeprom_update):
    cache = {"checked_at": 1, "firmware": {"version": FW_VER, "update": firmware_update, "files": []},
             "eeprom": {"version": "2026-10-30", "build_timestamp": TS_NEW, "channel": "default",
                        "package": EE_VER, "files": [], "update": eeprom_update}}
    with open(os.path.join(lab.run, "unitotem-firmware.check.json"), "w") as f:
        json.dump(cache, f)


def read_progress_file(lab):
    with open(os.path.join(lab.run, "unitotem-firmware.progress")) as f:
        return json.load(f)


def test_apply_parent(lab_dir, keyring):
    # busy: the operation lock is held
    lab = Lab(os.path.join(lab_dir, "p-busy"), keyring=keyring)
    with open(os.path.join(lab.run, "unitotem-firmware.lock"), "a+") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with fake_start([]) as calls:
            rc, out = run_main(["--json", "apply"], lab)
    check("apply busy: rc 12", rc == 12 and out["error_code"] == "busy", str(out))
    check("apply busy: nothing started", calls == [])

    # blockers, each refused before start (exit 14, blockers listed)
    lab = Lab(os.path.join(lab_dir, "p-uv"), keyring=keyring, throttled="0x1")
    with fake_start([]) as calls:
        rc, out = run_main(["--json", "apply"], lab)
    check("apply under-voltage: rc 14 blocked", rc == 14 and out["error_code"] == "blocked", str(out))
    check("apply under-voltage: blockers listed", out.get("blockers") == ["under-voltage"], str(out))
    check("apply under-voltage: nothing started", calls == [])

    lab = Lab(os.path.join(lab_dir, "p-pend"), keyring=keyring, pending=True)
    with fake_start([]) as calls:
        rc, out = run_main(["--json", "apply"], lab)
    check("apply pending-confirm: rc 14 with blocker", rc == 14 and out.get("blockers") == ["pending-confirm"], str(out))

    lab = Lab(os.path.join(lab_dir, "p-ro"), keyring=keyring)
    orig = F.fs_writable
    F.fs_writable = lambda path: False
    try:
        with fake_start([]) as calls:
            rc, out = run_main(["--json", "apply"], lab)
    finally:
        F.fs_writable = orig
    check("apply not-writable: rc 14 with blocker", rc == 14 and out.get("blockers") == ["not-writable"], str(out))

    lab = Lab(os.path.join(lab_dir, "p-nothing"), keyring=keyring)
    write_cache(lab, firmware_update=False, eeprom_update=False)
    with fake_start([]) as calls:
        rc, out = run_main(["--json", "apply"], lab)
    check("apply nothing to do: rc 10", rc == 10 and out["error_code"] == "nothing-to-do", str(out))
    check("apply nothing to do: nothing started", calls == [])

    lab = Lab(os.path.join(lab_dir, "p-pi3eep"), model="Raspberry Pi 3 Model B Plus Rev 1.3", keyring=keyring)
    with fake_start([]) as calls:
        rc, out = run_main(["--json", "apply", "--eeprom"], lab)
    check("apply --eeprom on Pi 3: no-eeprom", rc == 2 and out["error_code"] == "no-eeprom", str(out))

    lab = Lab(os.path.join(lab_dir, "p-start"), keyring=keyring, installed_ts=TS_OLD)
    with fake_start([]) as calls:
        rc, out = run_main(["--json", "apply"], lab)
    check("apply started (no cache): rc 0 with both targets",
          rc == 0 and out == {"started": True, "op": "apply", "files": True, "eeprom": True}, str(out))
    argv = calls[0] if calls else []
    check("apply start: systemd-run unit, Nice and idle I/O",
          argv[:9] == ["systemd-run", "--unit", "unitotem-firmware-apply", "--collect", "--quiet",
                       "-p", "Nice=19", "-p", "IOSchedulingClass=idle"], str(argv))
    check("apply start: child runs the foreground apply with both flags",
          argv[-5:] == ["--json", "apply", "--foreground", "--files", "--eeprom"], str(argv))
    check("apply start: no shell (argv list ends with the flags)", all(isinstance(x, str) for x in argv))

    lab = Lab(os.path.join(lab_dir, "p-fw-only"), keyring=keyring, installed_ts=TS_NEW)
    write_cache(lab, firmware_update=True, eeprom_update=False)
    with fake_start([]) as calls:
        rc, out = run_main(["--json", "apply"], lab)
    check("apply with only files pending: eeprom false",
          out == {"started": True, "op": "apply", "files": True, "eeprom": False}, str(out))

    lab = Lab(os.path.join(lab_dir, "p-pi3"), model="Raspberry Pi 3 Model B Plus Rev 1.3", keyring=keyring)
    with fake_start([]) as calls:
        rc, out = run_main(["--json", "apply"], lab)
    check("apply on Pi 3 without flags: files only", out.get("eeprom") is False and out.get("files") is True, str(out))


def test_apply_swap(lab_dir, gh, fpr, keyring):
    repo = Repo(gh, fpr)
    lab = Lab(os.path.join(lab_dir, "swap"), keyring=keyring, installed_ts=TS_NEW)
    lab.fat(old_fat())
    before = fat_state(lab.boot)
    with fake_net(FakeNet(repo.routes)), env(**lab.env()):
        rc, out = F.cmd_check(F.conf())
    check("swap: check reports the files update", rc == 0 and out["files"]["update"] is True, str(out))
    rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    check("swap: rc 0", rc == 0, str(out))
    check("swap: reports swapped pairs and bootcode, reboot required",
          out.get("swapped") == ["start.elf", "fixup.dat", "start4.elf", "fixup4.dat", "bootcode.bin"]
          and out.get("reboot_required") is True and out.get("eeprom_staged") is False, str(out))
    after = fat_state(lab.boot)
    for n in ("start.elf", "fixup.dat", "start4.elf", "fixup4.dat", "bootcode.bin"):
        check(f"swap: {n} is the package file", after.get(n) == FW_CONTENT[n])
    check("swap: no file created beyond the .bak files and the json",
          sorted(after) == sorted(list(before) + [n + ".bak" for n in
                                                  ("start.elf", "fixup.dat", "start4.elf", "fixup4.dat", "bootcode.bin")]
                                  + ["unitotem-firmware.json"]), str(sorted(after)))
    for n in ("start.elf", "fixup.dat", "start4.elf", "fixup4.dat", "bootcode.bin"):
        check(f"swap: {n}.bak holds the previous file", after.get(n + ".bak") == before[n])
    check("swap: no .new left", not [n for n in after if n.endswith(".new")], str(sorted(after)))
    check("swap: user file config.txt untouched", after["config.txt"] == before["config.txt"])
    check("swap: json records the package version",
          json.loads(read_bytes_file(os.path.join(lab.boot, "unitotem-firmware.json")))["version"] == FW_VER)
    prog = read_progress_file(lab)
    check("swap: progress done, reboot_required true",
          prog["op"] == "apply" and prog["state"] == "done" and prog["phase"] == "done"
          and prog["percent"] == 100 and prog["reboot_required"] is True and prog["error"] is None, str(prog))
    with fake_net(FakeNet(repo.routes)), env(**lab.env()):
        _, st = F.cmd_status(F.conf())
    check("swap: status shows the installed version and update false",
          st["files"]["installed"] == FW_VER and st["files"]["update"] is False and st["reboot_required"] is True,
          str(st["files"]))
    # a second run finds nothing to swap (idempotent)
    rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    check("swap redo: nothing swapped, reboot not required", rc == 0 and out["swapped"] == []
          and out["reboot_required"] is False, str(out))
    check("swap redo: FAT unchanged", fat_state(lab.boot) == after)


def test_apply_identical_pair(lab_dir, gh, fpr, keyring):
    repo = Repo(gh, fpr)
    lab = Lab(os.path.join(lab_dir, "identical"), keyring=keyring, installed_ts=TS_NEW)
    files = old_fat()
    files["start.elf"], files["fixup.dat"] = FW_CONTENT["start.elf"], FW_CONTENT["fixup.dat"]
    lab.fat(files)
    mtime = os.stat(os.path.join(lab.boot, "start.elf")).st_mtime_ns
    rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    after = fat_state(lab.boot)
    check("identical pair: not swapped, no .bak", rc == 0 and "start.elf.bak" not in after
          and "fixup.dat.bak" not in after and out["swapped"] == ["start4.elf", "fixup4.dat", "bootcode.bin"], str(out))
    check("identical pair: file not rewritten", os.stat(os.path.join(lab.boot, "start.elf")).st_mtime_ns == mtime)


def test_apply_failures(lab_dir, gh, fpr, keyring):
    repo = Repo(gh, fpr)

    # read-back mismatch: nothing swapped, the .new files removed
    lab = Lab(os.path.join(lab_dir, "readback"), keyring=keyring, installed_ts=TS_NEW)
    lab.fat(old_fat())
    before = fat_state(lab.boot)
    orig = F.sha256_file
    F.sha256_file = lambda p: "0" * 64 if p.endswith(".new") else orig(p)
    try:
        rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    finally:
        F.sha256_file = orig
    check("read-back mismatch: rc 2 verify-failed", rc == 2 and out["error_code"] == "verify-failed", str(out))
    check("read-back mismatch: FAT unchanged", fat_state(lab.boot) == before)
    check("read-back mismatch: progress failed in verify",
          read_progress_file(lab)["state"] == "failed" and read_progress_file(lab)["phase"] == "verify")

    # replace failure on the 3rd swap replace: every earlier replace is undone, FAT byte-identical
    lab = Lab(os.path.join(lab_dir, "replace"), keyring=keyring, installed_ts=TS_NEW)
    lab.fat(old_fat())
    before = fat_state(lab.boot)
    orig_replace, calls = F.fs_replace, {"swap": 0}
    def failing(src, dst):
        if src.endswith(".new") and not src.endswith(".bak.new"):
            calls["swap"] += 1
            if calls["swap"] == 3:
                raise OSError(errno.EIO, "injected replace failure")
        orig_replace(src, dst)
    F.fs_replace = failing
    try:
        rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    finally:
        F.fs_replace = orig_replace
    check("replace failure: swap-failed, rolled back", rc == 2 and out["error_code"] == "swap-failed"
          and out.get("rolled_back") is True, str(out))
    check("replace failure: exact FAT contents before and after (no .bak, no .new left)",
          fat_state(lab.boot) == before, str(sorted(fat_state(lab.boot))))
    check("replace failure: 3 swap replaces attempted", calls["swap"] == 3, str(calls))
    check("replace failure: progress failed in swap",
          read_progress_file(lab)["state"] == "failed" and read_progress_file(lab)["phase"] == "swap")

    # no name is ever absent from the FAT: checked after every replace of a successful swap
    lab = Lab(os.path.join(lab_dir, "never-absent"), keyring=keyring, installed_ts=TS_NEW)
    lab.fat(old_fat())
    required = {"start.elf", "fixup.dat", "start4.elf", "fixup4.dat", "bootcode.bin"}
    seen = {"steps": 0, "missing": []}
    orig_replace = F.fs_replace
    def watching(src, dst):
        orig_replace(src, dst)
        seen["steps"] += 1
        absent = sorted(n for n in required if not os.path.exists(os.path.join(lab.boot, n)))
        if absent:
            seen["missing"].append((src, absent))
    F.fs_replace = watching
    try:
        rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    finally:
        F.fs_replace = orig_replace
    check("never absent: replace steps observed and no name missing after any step",
          rc == 0 and seen["steps"] >= 10 and seen["missing"] == [], str(seen))

    # the same watch during a rollback: no name is absent at any step of the undo either
    lab = Lab(os.path.join(lab_dir, "never-absent-undo"), keyring=keyring, installed_ts=TS_NEW)
    lab.fat(old_fat())
    seen = {"steps": 0, "missing": []}
    orig_replace, calls = F.fs_replace, {"swap": 0}
    def watching_fail(src, dst):
        if src.endswith(".new") and not src.endswith(".bak.new"):
            calls["swap"] += 1
            if calls["swap"] == 4:
                raise OSError(errno.EIO, "injected replace failure")
        orig_replace(src, dst)
        seen["steps"] += 1
        absent = sorted(n for n in required if not os.path.exists(os.path.join(lab.boot, n)))
        if absent:
            seen["missing"].append((src, absent))
    F.fs_replace = watching_fail
    try:
        rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    finally:
        F.fs_replace = orig_replace
    check("never absent during rollback: no name missing at any step",
          out.get("rolled_back") is True and seen["missing"] == [], str(seen))

    # stale .new files of an interrupted run are removed and the swap is repeated
    lab = Lab(os.path.join(lab_dir, "stale"), keyring=keyring, installed_ts=TS_NEW)
    lab.fat(old_fat())
    for n in ("start4.elf.new", "bootcode.bin.new", "unitotem-firmware.json.new"):
        with open(os.path.join(lab.boot, n), "wb") as f:
            f.write(b"junk from an interrupted run")
    rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    after = fat_state(lab.boot)
    check("stale .new: removed, swap completed", rc == 0 and after["bootcode.bin"] == FW_CONTENT["bootcode.bin"]
          and not [n for n in after if n.endswith(".new")], str(sorted(after)))

    # under-voltage at start: refused inside the run (exit 14), nothing written
    lab = Lab(os.path.join(lab_dir, "uv-start"), keyring=keyring, installed_ts=TS_NEW, throttled="0x1")
    lab.fat(old_fat())
    before = fat_state(lab.boot)
    rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    check("under-voltage in the run: rc 14 blocked", rc == 14 and out["error_code"] == "blocked"
          and out["blockers"] == ["under-voltage"], str(out))
    check("under-voltage in the run: FAT unchanged", fat_state(lab.boot) == before)

    # under-voltage appears between start and swap
    lab = Lab(os.path.join(lab_dir, "uv-mid"), keyring=keyring, installed_ts=TS_NEW)
    lab.fat(old_fat())
    before = fat_state(lab.boot)
    seq = iter(["0x0", "0x1"])
    orig_thr = F.read_throttled
    F.read_throttled = lambda c: int(next(seq, "0x1"), 16)
    try:
        rc, out = run_main(["--json", "apply", "--foreground", "--files"], lab, repo.routes)
    finally:
        F.read_throttled = orig_thr
    check("under-voltage before the swap: rc 2 blocked, nothing swapped", rc == 2
          and out["error_code"] == "blocked" and fat_state(lab.boot) == before, str(out))
    check("under-voltage before the swap: no .new left", not [n for n in fat_state(lab.boot) if n.endswith(".new")])


def test_apply_eeprom(lab_dir, gh, fpr, keyring):
    repo = Repo(gh, fpr, ee_entries=default_ee("pi4"))
    lab = Lab(os.path.join(lab_dir, "eeprom"), keyring=keyring, installed_ts=TS_OLD)
    lab.fat(fat_same())
    os.makedirs(os.path.join(lab.run, "systemd", "system"))
    cur = os.path.join(lab.td, "running.conf")
    with open(cur, "w") as f:
        f.write("BOOT_ORDER=0xf41\nWAKE_ON_GPIO=0\nPOWER_OFF_ON_HALT=0\n")
    log = os.path.join(lab.td, "argv.log")
    with raw_env({"FW_TEST_CUR_CONFIG": cur, "FW_TEST_ARGV_LOG": log}):
        rc, out = run_main(["--json", "apply", "--foreground", "--eeprom"], lab, repo.routes)
        check("eeprom: rc 0, staged, reboot required", rc == 0 and out["eeprom_staged"] is True
              and out["reboot_required"] is True and out["swapped"] == [], str(out))
        with open(log) as f:
            calls = [json.loads(x) for x in f if x.strip()]
        check("eeprom: running config read with list args", len(calls) >= 1 and calls[0][0] == "--out"
              and calls[0][1].endswith("running.conf"), str(calls))
        write = next((c for c in calls if "--timestamp" in c), [])
        check("eeprom: image built with the running config embedded",
              "--config" in write and write[write.index("--config") + 1].endswith("running.conf")
              and "--out" in write, str(write))
        upd = os.path.join(lab.boot, "pieeprom.upd")
        image = read_bytes_file(upd)
        check("eeprom: pieeprom.upd is the 2711 image of the new build",
              len(image) == F.EE_SIZE["pi4"] and F.build_timestamp(upd) == TS_NEW, str(len(image)))
        cfg = read_bytes_file(cur)
        check("eeprom: config embedded in the image",
              image[0x20000:0x20000 + 8 + len(cfg) + 1] == b"BOOTCONF" + cfg + b"\0")
        sig = read_bytes_file(os.path.join(lab.boot, "pieeprom.sig")).decode().splitlines()
        check("eeprom: sig holds sha256, ts and target-soc",
              sig[0] == hashlib.sha256(image).hexdigest() and sig[1].startswith("ts: ")
              and sig[2] == "target-soc: 2711" and len(sig) == 3, str(sig))
        check("eeprom: recovery.bin is the package file", read_bytes_file(os.path.join(lab.boot, "recovery.bin"))
              == b"R" * 100)
        check("eeprom: suspend blocked until reboot", b"AllowSuspend=no" in read_bytes_file(os.path.join(
            lab.run, "systemd", "sleep.conf.d", "40-unitotem-firmware-pending.conf")))
        with fake_net(FakeNet(repo.routes)), env(**lab.env()):
            _, st = F.cmd_status(F.conf())
        check("eeprom: status shows pending", st["eeprom"]["pending"] is True and st["reboot_required"] is True)

        # second run: image already staged, nothing written (only the two reads)
        before_n = len(calls)
        rc, out = run_main(["--json", "apply", "--foreground", "--eeprom"], lab, repo.routes)
        with open(log) as f:
            calls2 = [json.loads(x) for x in f if x.strip()][before_n:]
        check("eeprom redo: nothing staged, no image built", rc == 0 and out["eeprom_staged"] is False
              and not any("--timestamp" in c for c in calls2) and out["reboot_required"] is True, str(calls2))

    # a configuration shorter than three lines is not embedded (as rpi-eeprom)
    lab = Lab(os.path.join(lab_dir, "eeprom-short"), keyring=keyring, installed_ts=TS_OLD)
    lab.fat(fat_same())
    cur = os.path.join(lab.td, "running.conf")
    with open(cur, "w") as f:
        f.write("WAKE_ON_GPIO=0\n")
    log = os.path.join(lab.td, "argv.log")
    with raw_env({"FW_TEST_CUR_CONFIG": cur, "FW_TEST_ARGV_LOG": log}):
        rc, out = run_main(["--json", "apply", "--foreground", "--eeprom"], lab, repo.routes)
    with open(log) as f:
        calls = [json.loads(x) for x in f if x.strip()]
    write = next((c for c in calls if "--timestamp" in c), [])
    check("eeprom short config: image built without --config", rc == 0 and write and "--config" not in write,
          str(write))

    # Pi 5: the 2712 image and its sig target
    repo5 = Repo(gh, fpr, ee_entries=default_ee("pi5"))
    lab = Lab(os.path.join(lab_dir, "eeprom-pi5"), model="Raspberry Pi 5 Model B Rev 1.0", keyring=keyring,
              installed_ts=TS_OLD)
    lab.fat(fat_same())
    cur = os.path.join(lab.td, "running.conf")
    with open(cur, "w") as f:
        f.write("BOOT_ORDER=0xf461\nPOWER_OFF_ON_HALT=0\nWAKE_ON_GPIO=1\n")
    with raw_env({"FW_TEST_CUR_CONFIG": cur, "FW_TEST_ARGV_LOG": os.path.join(lab.td, "argv.log")}):
        rc, out = run_main(["--json", "apply", "--foreground", "--eeprom"], lab, repo5.routes)
    sig = read_bytes_file(os.path.join(lab.boot, "pieeprom.sig")).decode().splitlines()
    check("eeprom pi5: 2 MiB image, target-soc 2712", rc == 0 and os.path.getsize(
        os.path.join(lab.boot, "pieeprom.upd")) == F.EE_SIZE["pi5"] and sig[2] == "target-soc: 2712", str(out))


def test_apply_pi3_no_eeprom(lab_dir, gh, fpr, keyring):
    repo = Repo(gh, fpr)
    lab = Lab(os.path.join(lab_dir, "pi3-apply"), model="Raspberry Pi 3 Model B Plus Rev 1.3", keyring=keyring,
              installed_ts=TS_NEW)
    lab.fat(old_fat())
    log = os.path.join(lab.td, "argv.log")
    with raw_env({"FW_TEST_ARGV_LOG": log, "FW_TEST_CUR_CONFIG": os.path.join(lab.td, "none")}):
        rc, out = run_main(["--json", "apply", "--foreground"], lab, repo.routes)
    check("Pi 3 apply: eeprom false, files swapped", rc == 0 and out["eeprom"] is False and out["files"] is True
          and out["eeprom_staged"] is False, str(out))
    check("Pi 3 apply: rpi-eeprom package never requested", f"{BASE}/{EE_FN}" not in LAST_NET.calls,
          str(LAST_NET.calls))
    check("Pi 3 apply: no pieeprom or recovery file on the FAT",
          not any(n in fat_state(lab.boot) for n in ("pieeprom.upd", "pieeprom.sig", "recovery.bin")))
    check("Pi 3 apply: config tool never run", not os.path.exists(log))


def read_bytes_file(path):
    with open(path, "rb") as f:
        return f.read()


def main():
    global OK, FAIL
    if not shutil.which("gpg") or not shutil.which("gpgv"):
        print("FAIL: gpg and gpgv are needed (the test builds a real signed archive)")
        return 1
    before = snapshot()
    with tempfile.TemporaryDirectory(prefix="unitotem-fw-test-") as td:
        gh = os.path.join(td, "gnupg-main")
        fpr = new_key(gh)
        keyring = os.path.join(td, "raspberrypi-test.gpg")
        with open(keyring, "wb") as f:
            f.write(gpg(gh, "--export", fpr))
        lab_dir = os.path.join(td, "labs")
        os.makedirs(lab_dir)
        try:
            test_model_and_pairs(lab_dir)
            test_status_device(lab_dir)
            test_blockers(lab_dir)
            test_check(lab_dir, gh, fpr, keyring)
            test_refusals(lab_dir, gh, fpr, keyring)
            test_eeprom_and_status_after(lab_dir, gh, fpr, keyring)
            test_main_json(lab_dir)
            test_apply_parent(lab_dir, keyring)
            test_apply_swap(lab_dir, gh, fpr, keyring)
            test_apply_identical_pair(lab_dir, gh, fpr, keyring)
            test_apply_failures(lab_dir, gh, fpr, keyring)
            test_apply_eeprom(lab_dir, gh, fpr, keyring)
            test_apply_pi3_no_eeprom(lab_dir, gh, fpr, keyring)
        finally:
            for home in (gh, os.path.join(td, "gh2")):
                if os.path.isdir(home):
                    subprocess.run(["gpgconf", "--homedir", home, "--kill", "gpg-agent"],
                                   capture_output=True, check=False)
    after = snapshot()
    check("users.json and the real /run, /boot unitotem-firmware files unchanged", before == after,
          f"{before} -> {after}")
    print(f"\n{OK} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())

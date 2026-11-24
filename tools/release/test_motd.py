#!/usr/bin/env python3
"""Test of unitotem-motd: formatting, row sources and rendered text on fixture trees.

  python3 tools/release/test_motd.py
"""
import importlib.machinery, importlib.util, json, os, shutil, sys, tempfile

sys.dont_write_bytecode = True  # no .pyc written into the repo
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BASE = tempfile.mkdtemp(prefix="test-motd-")  # every fixture lives under BASE
os.environ["UNITOTEM_MOTD_ROOT"] = BASE
loader = importlib.machinery.SourceFileLoader("motd", os.path.join(ROOT, "unitotem/files/unitotem-motd"))
spec = importlib.util.spec_from_loader("motd", loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ok = fail = 0

REAL_STATVFS, REAL_IPV4, REAL_THROTTLE = os.statvfs, mod.ipv4, mod.throttle_value
THROTTLE = {"value": 0}
IPV4 = {}
DISK = {"blocks": 1000000, "free": 600000, "fail": False}
ESCAPED = []


class Vfs:
    f_frsize = 4096

    def __init__(self, blocks, free):
        self.f_blocks = blocks
        self.f_bfree = free


def fake_statvfs(path):
    # Fixture mount only: a path outside BASE is recorded and refused.
    if not path.startswith(BASE + os.sep):
        ESCAPED.append(path)
        raise OSError(2, "refused: not a fixture path", path)
    if DISK["fail"] or not os.path.isdir(path):
        raise OSError(5, "mocked: no data mount", path)
    return Vfs(DISK["blocks"], DISK["free"])


def fake_ipv4(ifname):
    return IPV4.get(ifname)


def fake_throttle():
    return THROTTLE["value"]


def check(name, cond):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name)


# Fixture tree: file path (relative to the root) -> text, or an int for a sparse file of that size.
FULL = {
    "usr/share/unitotem/unitotem-release": 'PRETTY_NAME="UniTotem 2026.11.54"\nVERSION_ID=2026.11.54\nUNITOTEM_BASE="Debian 13"\n',
    "usr/share/unitotem/release-version": "2026.11.54\n",
    "proc/device-tree/model": "Raspberry Pi 4 Model B Rev 1.5\x00",
    "proc/cmdline": "console=tty1 root=/dev/mmcblk0p2 unitotem.slot=a ro quiet\n",
    "mnt/data/unitotem/update/slots.json": json.dumps({
        "a": {"version": "2026.11.54", "valid": True, "prepared": True},
        "b": {"version": "2026.11.50", "valid": True, "prepared": False}}),
    "mnt/data/unitotem/update/auto-state.json": json.dumps({"available": True, "version": "2026.11.56"}),
    "proc/uptime": "183600.42 1234.56\n",
    "proc/loadavg": "0.52 0.48 0.40 1/234 5678\n",
    "proc/meminfo": "MemTotal:        3884352 kB\nMemAvailable:    2097152 kB\n",
    "sys/class/thermal/thermal_zone0/temp": "52341\n",
    "sys/class/net/lo/operstate": "unknown\n",
    "sys/class/net/end0/operstate": "up\n",
    "sys/class/net/wlan0/operstate": "down\n",
    "sys/class/drm/card0-DP-1/status": "disconnected\n",
    "sys/class/drm/card1-HDMI-A-1/status": "connected\n",
    "sys/class/drm/card1-HDMI-A-1/enabled": "enabled\n",
    "sys/class/drm/card1-HDMI-A-1/dpms": "On\n",
    "var/lib/unitotem/screen_state.json": json.dumps({"commanded_off": []}),
    "etc/unitotem/viewer_assignments.json": json.dumps([{"screen_name": "HDMI-A-1", "playlist_id": "main"}]),
    "etc/unitotem/playlists.json": json.dumps({"default": "main"}),
    "etc/unitotem/playlist_main.json": json.dumps({"name": "Lobby", "assets": [
        {"enabled": True, "url": "file:promo.mp4"},
        {"enabled": True, "url": "https://example.com/loop.mp4"},
        {"enabled": False, "url": "file:old.mp4"}]}),
    "var/lib/unitotem/uploaded/promo.mp4": 5 * 1048576,
    "var/lib/unitotem/uploaded/old.mp4": 7 * 1048576,
}
FULL_HEAD = ["UniTotem 2026.11.54", "Raspberry Pi 4 Model B Rev 1.5", "Debian 13"]
FULL_ROWS = [
    ("Slot", ["A  (other slot B 2026.11.50)"]),
    ("Updates", ["2026.11.56 available"]),
    ("Uptime", ["2 days 3 hours"]),
    ("Load", ["0.52 0.48 0.40", "CPU 52 C"]),
    ("Memory", ["1.7 GB of 3.7 GB"]),
    ("Data disk", ["1.5 GB of 3.8 GB (40%)"]),
    ("Network", ["end0 192.0.2.197    wlan0 down"]),
    ("Screen", ["HDMI-A-1 on", "playlist Lobby", "2 assets, 5 MB"]),
]
FULL_TEXT = "\n".join([
    "",
    "UniTotem 2026.11.54   Raspberry Pi 4 Model B Rev 1.5   Debian 13",
    "",
    "Slot        A  (other slot B 2026.11.50)",
    "Updates     2026.11.56 available",
    "Uptime      2 days 3 hours",
    "Load        0.52 0.48 0.40    CPU 52 C",
    "Memory      1.7 GB of 3.7 GB",
    "Data disk   1.5 GB of 3.8 GB (40%)",
    "Network     end0 192.0.2.197    wlan0 down",
    "Screen      HDMI-A-1 on    playlist Lobby    2 assets, 5 MB",
]) + "\n\n"


def write(root, files):
    for rel, content in files.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if isinstance(content, int):
            with open(path, "wb") as f:
                f.truncate(content)
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)


def variant(drop=(), over=None):
    # FULL minus the files under the dropped paths, with the overrides applied.
    files = {rel: c for rel, c in FULL.items()
             if not any(rel == d or rel.startswith(d + "/") for d in drop)}
    files.update(over or {})
    return files


CASE = [0]


def tree(files):
    # New fixture root under BASE; the module reads it from now on.
    CASE[0] += 1
    root = os.path.join(BASE, "case%02d" % CASE[0])
    os.makedirs(root)
    write(root, files)
    mod.ROOT = root
    return root


def reset():
    THROTTLE["value"] = 0
    IPV4.clear()
    IPV4["end0"] = "192.0.2.197"
    DISK.update(blocks=1000000, free=600000, fail=False)


def scenario(name, drop=(), over=None, remove=(), replace=None, head=None, ips=None,
             disk_free=600000, disk_fail=False, throttle=0):
    # Builds the fixture with some sources removed and compares the rows with FULL_ROWS.
    reset()
    IPV4.clear()
    IPV4.update(ips or {"end0": "192.0.2.197"})
    DISK["free"], DISK["fail"] = disk_free, disk_fail
    THROTTLE["value"] = throttle
    tree(variant(drop, over))
    h, rows = mod.build()
    want = dict(FULL_ROWS)
    for label in remove:
        want.pop(label, None)
    want.update(replace or {})
    check(name, dict(rows) == want and h == (FULL_HEAD if head is None else head))


def run():
    mod.ipv4, mod.throttle_value = fake_ipv4, fake_throttle
    os.statvfs = fake_statvfs
    check("module reads the fixture base, not the system", mod.ROOT == BASE)

    # fmt_size and fmt_kb: units and rounding
    check("fmt_size: 0 is 0 MB", mod.fmt_size(0) == "0 MB")
    check("fmt_size: MB below 1 GiB, floored", mod.fmt_size(1048575) == "0 MB" and mod.fmt_size(1073741823) == "1023 MB")
    check("fmt_size: 1 MiB is 1 MB", mod.fmt_size(1048576) == "1 MB")
    check("fmt_size: 1 GiB is 1.0 GB", mod.fmt_size(1073741824) == "1.0 GB")
    check("fmt_size: GB rounded to one decimal", mod.fmt_size(1116000000) == "1.0 GB" and mod.fmt_size(1353000000) == "1.3 GB")
    check("fmt_kb: KB converted to GB with one decimal", mod.fmt_kb(3884352) == "3.7 GB" and mod.fmt_kb(1572864) == "1.5 GB")
    check("fmt_kb: below 1 GiB stays in MB", mod.fmt_kb(524288) == "512 MB" and mod.fmt_kb(0) == "0 MB")

    # fmt_uptime: plural, singular, dropped zero parts
    for seconds, want in [(0, "less than a minute"), (59, "less than a minute"), (60, "1 minute"),
                          (120, "2 minutes"), (3600, "1 hour"), (3660, "1 hour 1 minute"),
                          (7200, "2 hours"), (86399, "23 hours 59 minutes"), (86400, "1 day"),
                          (90000, "1 day 1 hour"), (172800, "2 days"), (176400, "2 days 1 hour"),
                          (183600.42, "2 days 3 hours")]:
        check("fmt_uptime %s -> %s" % (seconds, want), mod.fmt_uptime(seconds) == want)

    # throttle_warnings: bit meanings, "now" wins over "since boot"
    for value, want in [(0, []), (0x1, ["under-voltage now"]), (0x10000, ["under-voltage since boot"]),
                        (0x4, ["throttled now"]), (0x40000, ["throttled since boot"]),
                        (0x50005, ["under-voltage now", "throttled now"]),
                        (0x50000, ["under-voltage since boot", "throttled since boot"]),
                        (0x10001, ["under-voltage now"]), (0x40004, ["throttled now"])]:
        check("throttle_warnings %#x" % value, mod.throttle_warnings(value) == want)

    # Every source missing: no exception, no rows
    reset()
    THROTTLE["value"] = None
    tree({})
    head, rows = mod.build()
    check("empty root: no header and no rows", head == [] and rows == [])
    check("empty root: rendered text is blank lines only", mod.render(head, rows) == "\n\n\n\n")
    mod.ROOT = os.path.join(BASE, "missing")
    head, rows = mod.build()
    check("missing root: build does not raise and has no rows", head == [] and rows == [])

    # Full fixture: exact rendered text
    reset()
    tree(variant())
    head, rows = mod.build()
    check("full fixture: header fields", head == FULL_HEAD)
    check("full fixture: row fields", rows == FULL_ROWS)
    check("full fixture: rendered text is exact", mod.render(head, rows) == FULL_TEXT)

    # Each row skipped independently when only its source is missing
    scenario("no uptime: only Uptime skipped", drop=["proc/uptime"], remove=["Uptime"])
    scenario("uptime unreadable: only Uptime skipped", over={"proc/uptime": "abc\n"}, remove=["Uptime"])
    scenario("no loadavg: Load skipped", drop=["proc/loadavg"], remove=["Load"])
    scenario("no thermal zone: Load without CPU temperature", drop=["sys/class/thermal"],
             replace={"Load": ["0.52 0.48 0.40"]})
    scenario("no meminfo: Memory skipped", drop=["proc/meminfo"], remove=["Memory"])
    scenario("meminfo without MemAvailable: Memory skipped",
             over={"proc/meminfo": "MemTotal:        3884352 kB\n"}, remove=["Memory"])
    scenario("data mount missing: Data disk skipped", disk_fail=True, remove=["Data disk"])
    scenario("no net class: Network skipped", drop=["sys/class/net"], remove=["Network"])
    scenario("wlan0 up without address: shown as no address", over={"sys/class/net/wlan0/operstate": "up\n"},
             replace={"Network": ["end0 192.0.2.197    wlan0 no address"]}, ips={"end0": "192.0.2.197"})
    scenario("no drm class: Screen skipped", drop=["sys/class/drm"], remove=["Screen"])
    scenario("no release files: header keeps the model only", drop=["usr/share/unitotem"],
             head=["Raspberry Pi 4 Model B Rev 1.5"])
    scenario("release-version only: header from it, no base", drop=["usr/share/unitotem/unitotem-release"],
             head=["UniTotem 2026.11.54", "Raspberry Pi 4 Model B Rev 1.5"])
    scenario("no model: header without the model", drop=["proc/device-tree"],
             head=["UniTotem 2026.11.54", "Debian 13"])
    scenario("no device-tree: DMI vendor and name", drop=["proc/device-tree"],
             over={"sys/class/dmi/id/product_name": "NUC7i5BNH\n", "sys/class/dmi/id/sys_vendor": "Intel Corporation\n"},
             head=["UniTotem 2026.11.54", "Intel Corporation NUC7i5BNH", "Debian 13"])
    scenario("DMI vendor already in the name: not repeated", drop=["proc/device-tree"],
             over={"sys/class/dmi/id/product_name": "Intel NUC\n", "sys/class/dmi/id/sys_vendor": "Intel\n"},
             head=["UniTotem 2026.11.54", "Intel NUC", "Debian 13"])
    scenario("DMI generic name: no model", drop=["proc/device-tree"],
             over={"sys/class/dmi/id/product_name": "To be filled by O.E.M.\n"},
             head=["UniTotem 2026.11.54", "Debian 13"])
    scenario("no throttle tool: no Warnings row", throttle=None)
    scenario("garbage sources: no exception, valid rows kept", remove=["Uptime", "Memory"],
             replace={"Slot": ["A"]},
             over={"proc/meminfo": "garbage\n", "mnt/data/unitotem/update/slots.json": "[1, 2]",
                   "etc/unitotem/viewer_assignments.json": "{not json", "proc/uptime": "abc\n"})

    # Slot row variants
    scenario("no slot on the command line: both slots listed", over={"proc/cmdline": "console=tty1 quiet\n"},
             replace={"Slot": ["A 2026.11.54   B 2026.11.50"]})
    scenario("running slot B: other slot A", over={"proc/cmdline": "unitotem.slot=b\n"},
             replace={"Slot": ["B  (other slot A 2026.11.54)"]})
    scenario("other slot without version", over={"mnt/data/unitotem/update/slots.json": json.dumps(
        {"a": {"version": "2026.11.54"}, "b": {"valid": True}})},
             replace={"Slot": ["A  (other slot B)"]})
    scenario("invalid slot and no slots file: Slot skipped", over={"proc/cmdline": "unitotem.slot=x\n"},
             drop=["mnt/data/unitotem/update/slots.json"], remove=["Slot"])
    scenario("no cmdline and no slots file: Slot skipped", drop=["proc/cmdline", "mnt/data/unitotem/update/slots.json"],
             remove=["Slot"])
    scenario("no auto-state: Updates skipped", drop=["mnt/data/unitotem/update/auto-state.json"], remove=["Updates"])

    # Screen row variants
    scenario("no assignments and no playlists index: screen shown alone",
             drop=["etc/unitotem/viewer_assignments.json", "etc/unitotem/playlists.json"],
             replace={"Screen": ["HDMI-A-1 on"]})
    scenario("no playlist file: screen without playlist", drop=["etc/unitotem/playlist_main.json"],
             replace={"Screen": ["HDMI-A-1 on"]})
    scenario("upload missing: size 0 MB", drop=["var/lib/unitotem/uploaded/promo.mp4"],
             replace={"Screen": ["HDMI-A-1 on", "playlist Lobby", "2 assets, 0 MB"]})
    scenario("commanded off: screen off", over={"var/lib/unitotem/screen_state.json": json.dumps(
        {"commanded_off": ["HDMI-A-1"]})}, replace={"Screen": ["HDMI-A-1 off", "playlist Lobby", "2 assets, 5 MB"]})
    scenario("DPMS off: screen off", over={"sys/class/drm/card1-HDMI-A-1/dpms": "Off\n"},
             replace={"Screen": ["HDMI-A-1 off", "playlist Lobby", "2 assets, 5 MB"]})
    scenario("output disabled: screen off", over={"sys/class/drm/card1-HDMI-A-1/enabled": "disabled\n"},
             replace={"Screen": ["HDMI-A-1 off", "playlist Lobby", "2 assets, 5 MB"]})

    # Second connected output: continuation label
    reset()
    tree(variant(over={"sys/class/drm/card2-DP-2/status": "connected\n",
                       "sys/class/drm/card2-DP-2/enabled": "disabled\n",
                       "sys/class/drm/card2-DP-2/dpms": "On\n"}))
    head, rows = mod.build()
    check("second screen: first row labelled Screen, second with empty label",
          rows[-2:] == [("Screen", ["HDMI-A-1 on", "playlist Lobby", "2 assets, 5 MB"]),
                        ("", ["DP-2 off", "playlist Lobby", "2 assets, 5 MB"])])
    check("second screen: continuation line is indented to the value column",
          ("\n" + " " * 12 + "DP-2 off    playlist Lobby    2 assets, 5 MB\n") in mod.render(head, rows))

    # Playlist ids that are not plain identifiers are ignored
    scenario("playlist id with path component ignored", over={
        "etc/unitotem/viewer_assignments.json": json.dumps([{"screen_name": "HDMI-A-1", "playlist_id": "../x"}]),
        "etc/unitotem/playlist_../x.json": json.dumps({"name": "Trap", "assets": []})},
             replace={"Screen": ["HDMI-A-1 on"]})
    scenario("default playlist with path component ignored", drop=["etc/unitotem/viewer_assignments.json"],
             over={"etc/unitotem/playlists.json": json.dumps({"default": "../x"}),
                   "etc/unitotem/playlist_../x.json": json.dumps({"name": "Trap", "assets": []})},
             replace={"Screen": ["HDMI-A-1 on"]})

    # playlist_field: enabled assets only, sizes only for plain files in the upload dir
    reset()
    tree(variant(over={"etc/unitotem/playlist_lobby.json": json.dumps({"name": "Lobby", "assets": [
        {"enabled": True, "url": "file:promo.mp4"},
        {"enabled": 1, "url": "file:old.mp4"},
        {"enabled": "true", "url": "file:old.mp4"},
        "junk",
        {"enabled": True, "url": "file:../promo.mp4"},
        {"enabled": True, "url": "file:sub/promo.mp4"},
        {"enabled": True, "url": "file:."},
        {"enabled": True, "url": "file:missing.mp4"}]})}))
    check("playlist_field: counts enabled True entries, sizes only plain files",
          mod.playlist_field("lobby") == ["playlist Lobby", "5 assets, 5 MB"])
    reset()
    tree(variant(over={"etc/unitotem/playlist_bare.json": json.dumps({"assets": []})}))
    check("playlist_field: no name uses the id, empty list is 0 assets",
          mod.playlist_field("bare") == ["playlist bare", "0 assets, 0 MB"])
    check("playlist_field: missing file gives None", mod.playlist_field("nothere") is None)
    write(mod.ROOT, {"etc/unitotem/playlist_list.json": "[1]"})
    check("playlist_field: non-object document gives None", mod.playlist_field("list") is None)

    # Updates row variants
    def upd(drop=(), over=None):
        reset()
        tree(variant(drop, over))
        return mod.updates_row(mod.load_json(mod.STATE_DIR + "/slots.json"))

    NOAUTO = ["mnt/data/unitotem/update/auto-state.json"]
    staged = "mnt/data/unitotem/update/pending.json"
    check("updates: staged pending", upd(over={staged: json.dumps({"version": "2026.11.56", "staged": True})})
          == ("Updates", ["2026.11.56 staged, applies at reboot"]))
    check("updates: trial pending", upd(over={staged: json.dumps({"version": "2026.11.56"})})
          == ("Updates", ["trial of 2026.11.56 pending"]))
    check("updates: pending without version", upd(over={staged: json.dumps({"staged": False})})
          == ("Updates", ["trial of unknown pending"]))
    check("updates: unreadable pending file", upd(over={staged: "{bad"})
          == ("Updates", ["trial of unknown pending"]))
    check("updates: downloaded on the other slot, before auto-state", upd(over={
        "mnt/data/unitotem/update/slots.json": json.dumps({
            "a": {"version": "2026.11.54", "valid": True, "prepared": True},
            "b": {"version": "2026.11.56", "valid": True, "prepared": True}})})
          == ("Updates", ["2026.11.56 downloaded, applies at reboot"]))
    check("updates: running slot B, downloaded A", upd(over={
        "proc/cmdline": "unitotem.slot=b\n",
        "mnt/data/unitotem/update/slots.json": json.dumps({
            "a": {"version": "2026.11.56", "valid": True, "prepared": True},
            "b": {"version": "2026.11.54", "valid": True, "prepared": True}})})
          == ("Updates", ["2026.11.56 downloaded, applies at reboot"]))
    check("updates: other slot not valid is not downloaded", upd(over={
        "mnt/data/unitotem/update/slots.json": json.dumps({
            "a": {"version": "2026.11.54", "valid": True, "prepared": True},
            "b": {"version": "2026.11.56", "valid": False, "prepared": True}})})
          == ("Updates", ["2026.11.56 available"]))
    check("updates: older prepared slot is not reported", upd(over={
        "mnt/data/unitotem/update/slots.json": json.dumps({
            "a": {"version": "2026.11.54", "valid": True, "prepared": True},
            "b": {"version": "2026.11.50", "valid": True, "prepared": True}})})
          == ("Updates", ["2026.11.56 available"]))
    check("updates: auto-state available without version", upd(drop=[], over={
        "mnt/data/unitotem/update/auto-state.json": json.dumps({"available": True})})
          == ("Updates", ["update available"]))
    check("updates: auto-state none available", upd(over={
        "mnt/data/unitotem/update/auto-state.json": json.dumps({"available": False})})
          == ("Updates", ["none available"]))
    check("updates: nothing known gives no row", upd(drop=NOAUTO + ["mnt/data/unitotem/update/slots.json"]) is None)

    # Data disk threshold: warning above 85 %
    for free, pct, used_text, warn in [(140000, 86, "3.3 GB", True), (150000, 85, "3.2 GB", False)]:
        reset()
        DISK["free"] = free
        tree(variant())
        head, rows = mod.build()
        d = dict(rows)
        check("disk %d%%: data row text" % pct, d["Data disk"] == ["%s of 3.8 GB (%d%%)" % (used_text, pct)])
        check("disk %d%%: warning %s" % (pct, "shown" if warn else "absent"),
              (d.get("Warnings") == ["data disk above 85%"]) if warn else ("Warnings" not in d))
    scenario("disk 86% with throttle flags: warnings joined",
             disk_free=140000, throttle=0x50005,
             replace={"Data disk": ["3.3 GB of 3.8 GB (86%)"],
                      "Warnings": ["under-voltage now; throttled now; data disk above 85%"]})

    # Hostile values: playlist and screen ids are validated, no exception
    # A matching entry with a non-string id wins over the default: no playlist shown.
    scenario("garbage assignment entries: matched non-string id shows no playlist",
             over={"etc/unitotem/viewer_assignments.json": json.dumps([None, 5, {"screen_name": "HDMI-A-1",
                                                                              "playlist_id": ["x"]}])},
             replace={"Screen": ["HDMI-A-1 on"]})

    # Real paths must never be read by the disk check
    check("no path outside the fixture base was touched", ESCAPED == [])


def main():
    global ok, fail
    try:
        run()
        check("render: control characters are replaced", mod.render(["a\x1b[31m"], [("X", ["b\nc"])]) == "\na?[31m\n\nX           b?c\n\n")
    finally:
        os.statvfs = REAL_STATVFS
        mod.ipv4, mod.throttle_value = REAL_IPV4, REAL_THROTTLE
        shutil.rmtree(BASE)


main()
print("%d passed, %d failed" % (ok, fail)); raise SystemExit(1 if fail else 0)

#!/usr/bin/env python3
"""Test of unitotem-wifi-roam: scan parsing and the choice of the access point to roam to.

  python3 tools/release/test_wifi_roam.py
"""
import importlib.machinery, importlib.util, os

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
loader = importlib.machinery.SourceFileLoader("wr", os.path.join(ROOT, "unitotem/files/unitotem-wifi-roam"))
spec = importlib.util.spec_from_loader("wr", loader); wr = importlib.util.module_from_spec(spec); loader.exec_module(wr)
ok = fail = 0


def check(name, cond):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name)


SCAN = ("bssid / frequency / signal level / flags / ssid\n"
        "96:28:de:02:91:e7\t2432\t-66\t[WPA2-PSK-CCMP][ESS]\tHome\n"
        "4a:98:23:91:06:4f\t2437\t-40\t[WPA2-PSK-CCMP][ESS]\tHome\n"
        "ba:08:ca:a7:f5:e5\t5180\t-45\t[WPA2-PSK-CCMP][ESS]\tHome5\n"
        "aa:bb:cc:dd:ee:ff\t2412\t-30\t[ESS]\t\n")
cfg = dict(wr.DEFAULTS)
scan = wr.parse_scan(SCAN)
check("scan results parsed, header skipped, empty SSID kept", len(scan) == 4 and scan[0] == ("96:28:de:02:91:e7", -66, "Home") and scan[3][2] == "")
check("status parsed", wr.parse_status("bssid=aa\nssid=Home\nwpa_state=COMPLETED\n")["ssid"] == "Home")
check("roams from the weak access point to the strong one of the same SSID", wr.pick("96:28:de:02:91:e7", -66, "Home", scan, cfg, {}, 0) == "4a:98:23:91:06:4f")
check("another SSID is never a target", wr.pick("96:28:de:02:91:e7", -66, "Other", scan, cfg, {}, 0) is None)
check("a difference below the margin does not roam", wr.pick("96:28:de:02:91:e7", -48, "Home", scan, cfg, {}, 0) is None)
check("an access point that failed recently is skipped", wr.pick("96:28:de:02:91:e7", -66, "Home", scan, cfg, {"4a:98:23:91:06:4f": 100}, 50) is None)
check("it is tried again once the ignore time is over", wr.pick("96:28:de:02:91:e7", -66, "Home", scan, cfg, {"4a:98:23:91:06:4f": 100}, 150) == "4a:98:23:91:06:4f")
check("the strongest of several candidates wins", wr.pick("x", -80, "Home", scan + [("11:22:33:44:55:66", -35, "Home")], cfg, {}, 0) == "11:22:33:44:55:66")
print("%d passed, %d failed" % (ok, fail)); raise SystemExit(1 if fail else 0)

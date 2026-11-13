#!/usr/bin/env python3
"""Host-side test of the static address that reaches the OTA fallback on the kernel command line: `ota_net_from_cmdline` of deploy/ota-engine.sh
(the fallback side) and `build_legacy_cmdline` of deploy/remote-deploy.sh (the arming side), both cut out of the real script text and run in bash.

  python3 tools/release/test_ota_net_cmdline.py
"""
import os, re, subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
ENGINE = open(os.path.join(ROOT, "deploy/ota-engine.sh")).read()
DEPLOY = open(os.path.join(ROOT, "deploy/remote-deploy.sh")).read()
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def cut(text, name):
    m = re.search(r"^%s\(\) \{[^\n]*\n.*?^\}\n" % name, text, re.S | re.M)
    assert m, name + " not found"
    return m.group(0)


NET = cut(ENGINE, "ota_net_from_cmdline")
LEGACY = cut(DEPLOY, "build_legacy_cmdline")


def fallback(cmdline, pre=""):
    script = ("set -u\nlog() { echo \"LOG: $*\"; }\ncmdline_get() { local t; for t in $CMDLINE; do case \"$t\" in \"$1=\"*) printf '%s\\n' \"${t#*=}\"; return 0;; esac; done; return 1; }\n"
              + pre + NET + "\nota_net_from_cmdline\necho \"MODE=${OTA_NET_MODE:-} ADDR=${OTA_NET_ADDR:-} GW=${OTA_NET_GW:-} LINK=${OTA_NET_LINK:-}\"\n")
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=dict(os.environ, CMDLINE=cmdline))
    return r.stdout, r.returncode


out, rc = fallback("quiet unitotem.ota=1 unitotem.ota.addr=10.113.6.7/24 unitotem.ota.gw=10.113.6.254")
check("address and gateway accepted", rc == 0 and "MODE=static ADDR=10.113.6.7/24 GW=10.113.6.254 LINK=wired" in out, out)
out, rc = fallback("unitotem.ota.addr=10.113.6.7/24")
check("address without gateway", rc == 0 and "MODE=static ADDR=10.113.6.7/24 GW= " in out, out)
out, rc = fallback("quiet unitotem.ota=1")
check("no address: nothing set (DHCP stays)", rc == 0 and "MODE= ADDR= GW=" in out, out)
for bad in ("10.113.6.7", "10.113.6.7/33", "10.113.6.7/0", "10.113.6.300/24", "10.113.6/24", "a.b.c.d/24", "10.113.6.7/24;reboot", "$(id)/24"):
    out, rc = fallback("unitotem.ota.addr=" + bad)
    check("bad address %r ignored" % bad, rc == 0 and "MODE= ADDR=" in out and "ignored" in out, out)
out, rc = fallback("unitotem.ota.addr=10.113.6.7/24 unitotem.ota.gw=10.113.6.999")
check("bad gateway dropped, address kept", rc == 0 and "MODE=static ADDR=10.113.6.7/24 GW= " in out, out)
out, rc = fallback("unitotem.ota.addr=10.113.6.7/24 unitotem.ota.gw=1.2.3.4", pre="OTA_NET_MODE=dhcp; OTA_NET_ADDR=; OTA_NET_GW=9.9.9.9\n")
check("command line replaces the file values", rc == 0 and "GW=1.2.3.4" in out and "MODE=static" in out, out)


def arming(netmode, link="wired", addr="10.113.6.7/24", gw="10.113.6.254", arch="amd64"):
    script = ("set -u\ndie() { echo \"DIE: $*\"; exit 1; }\ndeclare -A P\nP[NETMODE]=%s; P[NETLINK]=%s; P[NETADDR]=%s; P[NETGW]=%s\nOPT_CONSOLE=''; ARCH=%s\n" % (netmode, link, addr, gw, arch)
              + LEGACY + "\nbuild_legacy_cmdline 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAxUmCj8kynxkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'\n")
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    return r.stdout.strip(), r.returncode


out, rc = arming("static")
check("static wired node: address and gateway on the command line", rc == 0 and "unitotem.ota.addr=10.113.6.7/24" in out and "unitotem.ota.gw=10.113.6.254" in out, out)
check("command line stays under the 400 character limit", rc == 0 and len(out) < 400, str(len(out)))
out, rc = arming("dhcp")
check("DHCP node: no address on the command line", rc == 0 and "unitotem.ota.addr" not in out, out)
out, rc = arming("static", link="wifi")
check("wifi node: no address on the command line", rc == 0 and "unitotem.ota.addr" not in out, out)
out, rc = arming("static", gw="")
check("static node without gateway: address only", rc == 0 and "unitotem.ota.addr=10.113.6.7/24" in out and "unitotem.ota.gw" not in out, out)


RECOVER = cut(DEPLOY, "recover_net_from_cmdline")


def recovering(cmdline, dns="", pre=""):
    script = ("set -u\ndie() { echo \"DIE: $*\"; exit 1; }\ndeclare -A P\nOPT_NET_DNS='%s'\n%s" % (dns, pre) + RECOVER
              + "\nrecover_net_from_cmdline '%s'\necho \"MODE=${P[NETMODE]:-} LINK=${P[NETLINK]:-} ADDR=${P[NETADDR]:-} GW=${P[NETGW]:-} DNS=${P[NETDNS]:-}\"\n" % cmdline)
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    return r.stdout.strip(), r.returncode


out, rc = recovering("quiet unitotem.ota=1 unitotem.ota.addr=10.113.6.7/24 unitotem.ota.gw=10.113.6.254", dns="192.167.48.2;1.1.1.1")
check("recover: address, gateway and DNS become the installed system's network", rc == 0 and out == "MODE=static LINK=wired ADDR=10.113.6.7/24 GW=10.113.6.254 DNS=192.167.48.2;1.1.1.1", out)
out, rc = recovering("quiet unitotem.ota=1")
check("recover: a fallback armed without an address changes nothing", rc == 0 and out == "MODE= LINK= ADDR= GW= DNS=", out)
out, rc = recovering("unitotem.ota.addr=10.113.6.7/24 unitotem.ota.gw=x;reboot")
check("recover: a bad gateway is dropped, the address kept", rc == 0 and "ADDR=10.113.6.7/24 GW= " in out, out)
out, rc = recovering("unitotem.ota.addr=10.113.6.7/24", dns="8.8.8.8;evil")
check("recover: bad DNS list refused", rc == 1 and "DIE" in out, out)
out, rc = recovering("unitotem.ota.addr=10.113.6.7/24", pre="P[NETMODE]=dhcp\n")
check("recover: an already known network mode is not overridden", rc == 0 and out.startswith("MODE=dhcp"), out)

print(f"\n{ok} passed, {fail} failed")
raise SystemExit(1 if fail else 0)

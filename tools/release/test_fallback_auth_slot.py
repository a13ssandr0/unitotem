#!/usr/bin/env python3
"""Test of the slot whose DATA state the OTA fallback reads for its logins (fallback_auth_setup in deploy/ota-engine.sh):
unitotem.slot on the command line, else saved_entry of the boot FAT grubenv, else slot a. Fixtures only, nothing real is read.

  python3 tools/release/test_fallback_auth_slot.py
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.abspath(os.path.join(HERE, "..", "..", "deploy", "ota-engine.sh"))
ok = fail = 0
KEY_A = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
KEY_B = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)


def run(cmdline, grubenv, slots):
    """Runs fallback_auth_setup on a fixture; returns (open flag, authorized_keys text, passwd text)."""
    with tempfile.TemporaryDirectory() as td:
        data, boot, out = (os.path.join(td, d) for d in ("data", "boot", "out"))
        for s, (key, admin) in slots.items():
            if key: write(f"{data}/upper/root.{s}/.ssh/authorized_keys", key + "\n")
            write(f"{data}/upper/etc.{s}/group", f"sudo:x:27:{admin}\n" if admin else "sudo:x:27:\n")
            write(f"{data}/upper/etc.{s}/shadow", f"{admin}:$y$j9T$salt$hash:19000:0:99999:7:::\n" if admin else "")
        os.makedirs(boot)
        if grubenv is not None:
            write(f"{boot}/unitotem-grub/grub/grubenv", "# GRUB Environment Block\n" + grubenv + "\n####")
        write(f"{td}/cmd", cmdline + "\n")
        env = dict(os.environ, OTA_AUTH_ROOT=out, OTA_AUTH_DATADIR=data, OTA_AUTH_BOOTDIR=boot, OTA_AUTH_CMDLINE=f"{td}/cmd")
        r = subprocess.run(["bash", "-c", f'source "{ENGINE}"; fallback_auth_setup; echo "OPEN=$FALLBACK_OPEN"'],
                           capture_output=True, text=True, env=env)
        op = [l for l in r.stdout.splitlines() if l.startswith("OPEN=")]
        ak = open(f"{out}/root/.ssh/authorized_keys").read() if os.path.exists(f"{out}/root/.ssh/authorized_keys") else ""
        pw = open(f"{out}/etc/passwd").read() if os.path.exists(f"{out}/etc/passwd") else ""
        return (op[0] if op else r.stdout + r.stderr), ak, pw


both = {"a": (KEY_A, "adm_a"), "b": (KEY_B, "adm_b")}
o, ak, pw = run("quiet unitotem.slot=b", "saved_entry=slot-a", both)
check("command line slot b wins over saved_entry", KEY_B in ak and KEY_A not in ak and "adm_b" in pw, (ak, pw))
o, ak, pw = run("quiet unitotem.ota=1", "saved_entry=slot-b", both)
check("no unitotem.slot: saved_entry=slot-b selects slot b", KEY_B in ak and KEY_A not in ak and "adm_b" in pw and "adm_a" not in pw, (ak, pw))
o, ak, pw = run("quiet unitotem.ota=1", "saved_entry=slot-a", both)
check("no unitotem.slot: saved_entry=slot-a selects slot a", KEY_A in ak and KEY_B not in ak and "adm_a" in pw, (ak, pw))
o, ak, pw = run("quiet unitotem.ota=1", "saved_entry=ota-recovery", both)
check("saved_entry naming no slot: slot a", KEY_A in ak and KEY_B not in ak, (ak, pw))
o, ak, pw = run("quiet unitotem.ota=1", None, both)
check("no grubenv: slot a", KEY_A in ak and KEY_B not in ak, (ak, pw))
o, ak, pw = run("quiet unitotem.ota=1", "saved_entry=slot-b", {"a": (KEY_A, "adm_a"), "b": (None, None)})
check("current slot b without accounts: no key, no admin from slot a (open mode)", o == "OPEN=1" and ak.strip() == "" and "adm_a" not in pw, (o, ak, pw))
o, ak, pw = run("quiet unitotem.ota=1", "saved_entry=slot-b", both)
check("configured device is not in open mode", o == "OPEN=0", o)
print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

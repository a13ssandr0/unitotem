#!/usr/bin/env python3
"""Host-side test of ensure_tryboot_firmware() of deploy/remote-deploy.sh, with no target: the function is cut out of the real script text and run
in a bash harness whose ssh_t, backup_stream, do_probe and sleep are fakes that log every call. Judged on the exit status, the calls made and the
text printed. What it does NOT prove: the behaviour of apt or of a real board (the update was run on a real Pi 4 by hand, see the deploy doc).

  python3 tools/release/test_tryboot_firmware.py
"""
import os, re, subprocess, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCRIPT = open(os.path.join(ROOT, "deploy/remote-deploy.sh")).read()
m = re.search(r"^ensure_tryboot_firmware\(\) \{\n.*?^\}\n", SCRIPT, re.S | re.M)
assert m, "ensure_tryboot_firmware not found in deploy/remote-deploy.sh"
FUNC = m.group(0)
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


HARNESS = r"""
set -u
declare -A P
P[HAVE_UNITOTEM]=${HAVE:-0}; P[SOC]="${SOC:-raspberrypi,4-model-b brcm,bcm2711}"
FIRMWARE=${FW:-rpi}; TRYBOOT_CAPABLE=${TB:-0}; OPT_YES=${YES:-1}; OPT_FALLBACK_ONLY=0; OPT_NO_FIRMWARE_UPDATE=${NOFW:-0}
OPT_BACKUP_DIR="$WORK/backups"; TARGET_USERHOST=pi@10.0.0.5
log() { echo "LOG: $*"; }
die() { echo "DIE: $*"; exit 1; }
sleep() { :; }
clear_target_privilege() { echo "CALL clear_privilege" >> "$WORK/calls"; }
ssh_t() {
    echo "CALL ssh_t $1" >> "$WORK/calls"
    case "$1" in
        *dpkg-query*) [ "${PKG:-1}" = 1 ] ;;
        *get_throttled*) echo "throttled=${THR:-0x50000}" ;;
        *apt-get*) [ "${APT:-1}" = 1 ] ;;
        true) return 0 ;;
        *) return 0 ;;
    esac
}
backup_stream() { echo "CALL backup_stream $2" >> "$WORK/calls"; echo "$1/$2.tar.zst"; }
do_probe() { echo "CALL do_probe" >> "$WORK/calls"; TRYBOOT_CAPABLE=${TB_AFTER:-1}; }
"""


def run(**env):
    with tempfile.TemporaryDirectory() as td:
        e = dict(os.environ, WORK=td, **{k: str(v) for k, v in env.items()})
        r = subprocess.run(["bash", "-c", HARNESS + FUNC + "\nensure_tryboot_firmware\necho END rc=$?"], capture_output=True, text=True, env=e, input=env.get("ANSWER", "") + "\n")
        calls = open(os.path.join(td, "calls")).read() if os.path.exists(os.path.join(td, "calls")) else ""
        return r.stdout, r.returncode, calls


out, rc, calls = run(FW="uefi")
check("not a Raspberry: nothing done", rc == 0 and calls == "", out)
out, rc, calls = run(TB=1)
check("tryboot already announced: nothing done", rc == 0 and calls == "", out)
out, rc, calls = run(SOC="raspberrypi,3-model-b brcm,bcm2837")
check("Pi 3 (no EEPROM bootloader): nothing done", rc == 0 and calls == "", out)
out, rc, calls = run(HAVE=1)
check("installed UniTotem: nothing done", rc == 0 and calls == "", out)
out, rc, calls = run(NOFW=1)
check("--no-firmware-update: nothing done", rc == 0 and calls == "", out)
out, rc, calls = run(PKG=0)
check("package missing: refused before anything is written", rc == 1 and "raspberrypi-bootloader is not installed" in out and "apt-get" not in calls, out)
out, rc, calls = run(THR="0x50005")
check("under-voltage now: refused before anything is written", rc == 1 and "under-voltage right now" in out and "apt-get" not in calls and "backup_stream" not in calls, out)
out, rc, calls = run(THR="0x50000")
order = [c.split(" ", 2)[1] for c in calls.splitlines() if c.startswith("CALL ")]
check("past under-voltage only: update runs", rc == 0 and "apt-get install -y --only-upgrade" in calls, out)
check("order: package check, throttle, backup, apt, reboot, privilege reset, wait, probe",
      [c for c in order if c != "ssh_t"] == ["backup_stream", "clear_privilege", "do_probe"] and calls.index("backup_stream") < calls.index("apt-get") < calls.index("systemctl reboot") < calls.index("do_probe"), calls)
check("old firmware saved before the update", "unitotem-firmware-10.0.0.5-" in calls and "Old firmware files saved" in out, out)
check("only the firmware package is upgraded", "--only-upgrade" in calls and "raspberrypi-bootloader" in calls and "dist-upgrade" not in calls and "full-upgrade" not in calls, calls)
out, rc, calls = run(APT=0)
check("apt failure: stops with the saved files named", rc == 1 and "firmware update of 10.0.0.5 failed" in out and "old files" in out and "systemctl reboot" not in calls, out)
out, rc, calls = run(TB_AFTER=0)
check("still no tryboot after the update: stops", rc == 1 and "still reports no tryboot" in out, out)
out, rc, calls = run(YES=0, ANSWER="no")
check("not confirmed: nothing written", rc == 1 and "cancelled" in out and "apt-get" not in calls and "backup_stream" not in calls, out)
out, rc, calls = run(YES=0, ANSWER="YES")
check("confirmed: update runs", rc == 0 and "apt-get install" in calls, out)

print(f"\n{ok} passed, {fail} failed")
raise SystemExit(1 if fail else 0)

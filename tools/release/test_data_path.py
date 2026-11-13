#!/usr/bin/env python3
"""Host-side test of the data path choice of deploy/remote-deploy.sh (data_path_ok, data_path_setup, data_tunnel_stop), with no target: the functions
are cut out of the real script text and run in bash with fake ota_ssh, socat and ssh. Judged on the result, the calls made and the text printed.

  python3 tools/release/test_data_path.py
"""
import os, re, subprocess, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCRIPT = open(os.path.join(ROOT, "deploy/remote-deploy.sh")).read()
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def cut(name):
    m = re.search(r"^%s\(\) \{[^\n]*\n.*?^\}\n" % name, SCRIPT, re.S | re.M)
    assert m, name + " not found"
    return m.group(0)


FUNCS = "\n".join(cut(n) for n in ("data_tunnel_stop", "data_path_ok", "data_path_setup"))
HARNESS = r"""
set -euo pipefail
OPT_PORT=9700; DATA_HOSTIP_OVERRIDE=""; DATA_TUNNEL_PID=""
log() { echo "LOG: $*"; }
die() { echo "DIE: $*"; exit 1; }
socat() { sleep 20; }
wait_port_bound() { return 0; }
ota_auth_for() { OTA_AUTH_TARGET=root@10.0.0.7; }
ota_ssh() { echo "ota_ssh $2" >> "$WORK/calls"; case "$2" in *"/dev/tcp/127.0.0.1/"*) return ${TUNNEL_OK:-0} ;; *) return ${DIRECT_OK:-0} ;; esac; }
_ota_ssh_exec() { echo "tunnel $*" >> "$WORK/calls"; [ "${TUNNEL_DIES:-0}" = 1 ] && return 1; sleep 20; }
sleep() { command sleep "${1:-0}" ; }
"""


def run(**env):
    with tempfile.TemporaryDirectory() as td:
        e = dict(os.environ, WORK=td, **{k: str(v) for k, v in env.items()})
        script = HARNESS + FUNCS + "\ndata_path_setup 10.0.0.7 192.168.160.81\necho \"OVERRIDE=[${DATA_HOSTIP_OVERRIDE}] TUNNEL_PID_SET=${DATA_TUNNEL_PID:+yes}\"\ndata_tunnel_stop\n"
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=e, timeout=60)
        calls = open(os.path.join(td, "calls")).read() if os.path.exists(os.path.join(td, "calls")) else ""
        return r.stdout, r.returncode, calls


out, rc, calls = run(DIRECT_OK=0)
check("target reaches the host: no tunnel, no override", rc == 0 and "OVERRIDE=[] TUNNEL_PID_SET=" in out and "tunnel " not in calls and "192.168.160.81/9700" in calls, out + calls)
out, rc, calls = run(DIRECT_OK=1, TUNNEL_OK=0)
check("target cannot reach the host: reverse tunnel, override 127.0.0.1", rc == 0 and "OVERRIDE=[127.0.0.1] TUNNEL_PID_SET=yes" in out and "-R 9700:127.0.0.1:9700" in calls and "-N" in calls, out + calls)
check("the tunnel is opened after the direct way failed and checked through loopback", calls.index("192.168.160.81/9700") < calls.index("tunnel ") < calls.index("127.0.0.1/9700"), calls)
out, rc, calls = run(DIRECT_OK=1, TUNNEL_OK=1)
check("tunnel up but the target cannot use it: stops", rc == 1 and "neither directly nor through a reverse tunnel" in out, out)
out, rc, calls = run(DIRECT_OK=1, TUNNEL_DIES=1)
check("tunnel ssh dies at once (forward refused): stops", rc == 1 and "neither directly nor through a reverse tunnel" in out, out)

print(f"\n{ok} passed, {fail} failed")
raise SystemExit(1 if fail else 0)

#!/usr/bin/env python3
"""Host-side test of the data path choice of deploy/remote-deploy.sh (data_path_ok, data_push_ok, data_path_setup, serve_data, data_wait), with no target:
the functions are cut out of the real script text and run in bash with fake ota_ssh, socat and ssh. Judged on the result, the calls made and the text printed.

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


FUNCS = "\n".join(cut(n) for n in ("run_bounded", "data_path_ok", "data_push_start", "data_push_ok", "serve_data", "wait_data_ready", "data_wait", "data_path_setup"))
HARNESS = r"""
set -euo pipefail
OPT_PORT=9700; DATA_HOSTIP_OVERRIDE=""; DATA_PUSH=0
log() { echo "LOG: $*"; }
die() { echo "DIE: $*"; exit 1; }
socat() { sleep 20; }
serve_file_once() { echo "serve_file_once $1 $2" >> "$WORK/calls"; echo 4242; }
wait_port_bound() { return 0; }
ota_auth_for() { OTA_AUTH_TARGET=root@10.0.0.7; }
ota_ssh() { echo "ota_ssh $2" >> "$WORK/calls"; case "$2" in *"/dev/tcp/127.0.0.1/"*) return ${PUSH_OK:-0} ;; *) return ${DIRECT_OK:-0} ;; esac; }
_ota_ssh_exec() { echo "push $*" >> "$WORK/calls"; cat > "$WORK/pushed" || true; }
sleep() { if [ "${1:-}" = 30 ]; then command sleep 30; else command sleep 0.05; fi; }
"""


def run(body, **env):
    with tempfile.TemporaryDirectory() as td:
        e = dict(os.environ, WORK=td, **{k: str(v) for k, v in env.items()})
        script = HARNESS + FUNCS + "\n" + body
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=e, timeout=60)
        calls = open(os.path.join(td, "calls")).read() if os.path.exists(os.path.join(td, "calls")) else ""
        return r.stdout, r.returncode, calls


SETUP = 'data_path_setup 10.0.0.7 192.168.160.81\necho "OVERRIDE=[${DATA_HOSTIP_OVERRIDE}] PUSH=${DATA_PUSH}"\n'
out, rc, calls = run(SETUP, DIRECT_OK=0)
check("target reaches the host: direct, no override", rc == 0 and "OVERRIDE=[] PUSH=0" in out and "push " not in calls and "192.168.160.81/9700" in calls, out + calls)
out, rc, calls = run(SETUP, DIRECT_OK=1, PUSH_OK=0)
check("target cannot reach the host: push through the session, override 127.0.0.1", rc == 0 and "OVERRIDE=[127.0.0.1] PUSH=1" in out, out + calls)
check("the push test brings the loopback up and pipes into an nc bound to it", "ip link set lo up; nc -l -p 9700 -s 127.0.0.1 -q 1" in calls, calls)
out, rc, calls = run(SETUP, DIRECT_OK=1, PUSH_OK=1)
check("neither way works: stops before anything is written", rc == 1 and "neither directly nor through the OTA session" in out, out)

out, rc, calls = run('DATA_PUSH=1\nf=$(mktemp "$WORK/f.XXXXXX"); printf PAYLOAD > "$f"\npid=$(serve_data 10.0.0.7 "$f")\ndata_wait "$pid"\ncat "$WORK/pushed"; echo\n')
check("push mode: the file goes into an nc listening on the target's loopback", rc == 0 and "ip link set lo up; nc -l -p 9700 -s 127.0.0.1 -q 2" in calls and "PAYLOAD" in out, out + calls)
out, rc, calls = run('DATA_PUSH=0\npid=$(serve_data 10.0.0.7 /some/file)\n')
check("direct mode: the file is served from this host", rc == 0 and "serve_file_once /some/file 9700" in calls and "push " not in calls, out + calls)
out, rc, calls = run('DATA_PUSH=1\ntime_start=$SECONDS\nsleep 30 &\nbg=$!\n( command sleep 0.3; kill $bg ) &\ndata_wait "$bg"\necho "waited-ok"\n')
check("data_wait returns when the pid is gone", rc == 0 and "waited-ok" in out, out)

out, rc, calls = run('set +e\nrun_bounded 5 true; echo "rc=$?"\nrun_bounded 5 false; echo "rc=$?"\nrun_bounded 1 sleep 30; echo "rc=$?"\n')
check("run_bounded: status of the command, 124 when it runs out of time", rc == 0 and out.split() == ["rc=0", "rc=1", "rc=124"], out)
out, rc, calls = run(SETUP, DIRECT_OK=1, PUSH_OK=0)
check("the target is asked to use /bin/bash (no timeout command in the fallback)", "timeout" not in calls and "/bin/bash -c" in calls, calls)

print(f"\n{ok} passed, {fail} failed")
raise SystemExit(1 if fail else 0)

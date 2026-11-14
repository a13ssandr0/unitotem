#!/usr/bin/env python3
"""Host-side test of the target side of the legacy BIOS-boot partition path (GPT ef02, cloner dd):
  cmd_restore_part (deploy/script/ota-engine.sh), dd branch, against a regular file standing for the partition: the data comes
     over a local TCP socket, the result is byte-identical to the xz-decompressed stream, and no partclone binary runs
     (a PATH with a failing partclone.restore shim).
Functions are cut out of the real script text. Temporary directories only; no device, no /etc, no /run.

  python3 tools/release/test_deploy_bios.py
"""
import lzma, os, random, re, socket, subprocess, sys, tempfile, threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RD_TEXT = open(os.path.join(ROOT, "deploy/script/remote-deploy.sh")).read()
ENG_TEXT = open(os.path.join(ROOT, "deploy/script/ota-engine.sh")).read()
LIB_TEXT = open(os.path.join(ROOT, "deploy/script/lib.sh")).read()
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def fn(text, name):
    """Source text of the shell function NAME (block form, closing brace in column 0, or one-line form)."""
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.S | re.M) \
        or re.search(r"^%s\(\) \{.*\}\n" % re.escape(name), text, re.M)
    if not m:
        raise SystemExit("FAIL: function %s not found in its script" % name)
    return m.group(0)


def sh(script, timeout=60):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=timeout)


with tempfile.TemporaryDirectory() as td:
    # ---- cmd_restore_part, dd branch ----------------------------------------------------------------------------------
    eng_parse = fn(ENG_TEXT, "parse_args")
    eng_need = fn(ENG_TEXT, "need")
    eng_pdev = fn(ENG_TEXT, "pdev_target")
    eng_cmd = fn(ENG_TEXT, "cmd_restore_part")
    OLD_B = '    [ -b "$part_dev" ] || fail "partition not found: $part_dev"'
    OLD_LOG = "    mkdir -p /var/log"
    check("harness: cmd_restore_part has the -b device test and the /var/log mkdir exactly once (both are replaced below)",
          eng_cmd.count(OLD_B) == 1 and eng_cmd.count(OLD_LOG) == 1)
    eng_cmd = eng_cmd.replace(OLD_B, '    [ -e "$part_dev" ] || fail "partition not found: $part_dev"')

    rng = random.Random(7)
    payload = rng.randbytes(300021)                 # not a multiple of 512: the last dd block is partial
    stream = lzma.compress(payload, format=lzma.FORMAT_XZ, check=lzma.CHECK_SHA256)
    oracle = subprocess.run(["xz", "-dc"], input=stream, capture_output=True).stdout
    check("oracle: the xz stream decompresses to the payload", oracle == payload)

    def run_restore(tag, cloner, data):
        d = os.path.join(td, tag)
        os.makedirs(os.path.join(d, "bin"))
        disk = os.path.join(d, "sdx")                  # pdev_target -> sdx5, a regular file of 800 sectors
        part = disk + "5"
        open(part, "wb").write(b"\xaa" * 409600)       # pre-filled so a truncation or a short write shows
        # PATH holds only the shims and the tools the function needs: no pv, no real partclone.
        for tool in ("dd", "unxz", "xz", "mkdir"):
            os.symlink(subprocess.run(["bash", "-c", f"command -v {tool}"], capture_output=True, text=True).stdout.strip(),
                       os.path.join(d, "bin", tool))
        open(os.path.join(d, "bin", "blockdev"), "w").write('#!/bin/sh\necho 800\n')
        open(os.path.join(d, "bin", "partclone.restore"), "w").write(
            f'#!/bin/sh\necho called >> "{d}/partclone.called"\nexit 99\n')
        for f in ("blockdev", "partclone.restore"): os.chmod(os.path.join(d, "bin", f), 0o755)
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0)); srv.listen(1); srv.settimeout(30)
        port = srv.getsockname()[1]

        def serve():
            try:
                conn, _ = srv.accept()
                with conn: conn.sendall(data)
            except OSError:
                pass
            finally:
                srv.close()
        th = threading.Thread(target=serve, daemon=True); th.start()
        cmd_text = eng_cmd.replace(OLD_LOG, '    mkdir -p "' + d + '/log"')
        script = f'''set -u
declare -A ARG
log() {{ echo "LOG: $*"; }}
fail() {{ echo "FAIL-ENGINE: $*"; exit 1; }}
resolve_disk() {{ echo "$1"; }}
ota_status_set() {{ echo "$*" >> "{d}/status.log"; }}
OTA_PCT_FILE="{d}/pct"
{eng_parse}
{eng_need}
{eng_pdev}
{cmd_text}
PATH="{d}/bin"
cmd_restore_part --disk "{disk}" --part 5 --cloner {cloner} --comp xz --used-bytes 1031168 --data-host 127.0.0.1 --data-port {port}
'''
        r = sh(script)
        th.join(5)
        pc = os.path.exists(os.path.join(d, "partclone.called"))
        st = open(os.path.join(d, "status.log")).read() if os.path.exists(os.path.join(d, "status.log")) else ""
        return r, part, pc, st

    r, part, pc, st = run_restore("dd", "dd", stream)
    got = open(part, "rb").read()
    check("dd branch: restore-part exits 0 and reports UNITOTEM_PART_RESTORED=5", r.returncode == 0 and "UNITOTEM_PART_RESTORED=5" in r.stdout, (r.stdout, r.stderr))
    check("dd branch: the partition stand-in is byte-identical to the xz-decompressed stream", got == oracle == payload,
          (len(got), len(oracle), got[:16]))
    check("dd branch: no partclone binary is invoked", not pc)
    check("dd branch: the status line names the dd cloner", "Writing partition 5 (dd)" in st, st)
    rc_, part_, pc_, _ = run_restore("ctl", "extfs", stream)
    check("control: the partclone path IS reached for cloner extfs (shim called, restore fails)", pc_ and rc_.returncode != 0
          and "UNITOTEM_PART_RESTORED" not in rc_.stdout, (rc_.stdout, rc_.stderr, pc_))

print("\n%d passed, %d failed" % (ok, fail)); sys.exit(1 if fail else 0)

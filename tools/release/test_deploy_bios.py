#!/usr/bin/env python3
"""Host-side test of the legacy BIOS-boot partition path (GPT ef02, cloner dd, action raw) of the deploy:
  1. load_parts (deploy/remote-deploy.sh) accepts an A/B (layout 2) parts set and resolves the partition numbers from it;
     a layout 1 set is refused.
  2. the parts.manifest loop of run_ota_sequence (deploy/remote-deploy.sh) routes the raw/dd block to restore-part with
     --cloner dd, with ota_ssh and the data channel replaced by local recorders.
  3. cmd_restore_part (deploy/ota-engine.sh), dd branch, against a regular file standing for the partition: the data comes
     over a local TCP socket, the result is byte-identical to the xz-decompressed stream, and no partclone binary runs
     (a PATH with a failing partclone.restore shim).
Functions are cut out of the real script text. Temporary directories only; no device, no /etc, no /run.

  python3 tools/release/test_deploy_bios.py
"""
import lzma, os, random, re, socket, subprocess, sys, tempfile, threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RD_TEXT = open(os.path.join(ROOT, "deploy/remote-deploy.sh")).read()
ENG_TEXT = open(os.path.join(ROOT, "deploy/ota-engine.sh")).read()
LIB_TEXT = open(os.path.join(ROOT, "deploy/lib.sh")).read()
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


# ---- fixture: a parts set shaped like the real one (EFI, ROOT_A, ROOT_B, DATA, BIOS) --------------------------------------
def manifest(layout=2, bios_num=5):
    hdr = (f"UNITOTEM_PARTS_PROTO=1\nUNITOTEM_LAYOUT={layout}\nUNITOTEM_ARCH=amd64\nUNITOTEM_SET_NAME=fixture-bios\n"
           "UNITOTEM_TABLE=gpt\nUNITOTEM_TABLE_FILE=layout.sfdisk\nUNITOTEM_SECTOR_SIZE=512\n"
           "UNITOTEM_BOOTCODE_FILE=bootcode.bin\nUNITOTEM_BOOTCODE_BYTES=440\nUNITOTEM_NPARTS=5\n"
           "UNITOTEM_DATA_PART=4\nUNITOTEM_HAS_ESP=1\nUNITOTEM_BOOTFS_PART=1\nUNITOTEM_TOTAL_USED_BYTES=3750231040\n\n")
    sha = "ab" * 32
    blocks = [
        [("", 1), ("LABEL", "EFI"), ("FSTYPE", "vfat"), ("CLONER", "fat"), ("ACTION", "filecopy"), ("START", 2048),
         ("SECTORS", 1048576), ("VOLID", "CA7B-4F1D"), ("STREAM_FILE", "p1-EFI.bootfs.tar.xz"),
         ("STREAM_BYTES", 135094816), ("STREAM_SHA256", sha), ("COMP", "xz")],
        [("", 2), ("LABEL", "ROOT_A"), ("FSTYPE", "ext4"), ("CLONER", "extfs"), ("ACTION", "restore"), ("START", 1050624),
         ("SECTORS", 10485760), ("USED_BYTES", 3749199872), ("STREAM_FILE", "p2-ROOT_A.ext4.pc.xz"),
         ("STREAM_BYTES", 1069755264), ("STREAM_SHA256", sha), ("COMP", "xz")],
        [("", 3), ("LABEL", "ROOT_B"), ("FSTYPE", "ext4"), ("CLONER", "none"), ("ACTION", "format"), ("START", 11536384),
         ("SECTORS", 10485760)],
        [("", 4), ("LABEL", "DATA"), ("FSTYPE", "ext4"), ("CLONER", "none"), ("ACTION", "data"), ("START", 22022144),
         ("SECTORS", 2097152)],
        [("", bios_num), ("LABEL", "BIOS"), ("FSTYPE", "none"), ("CLONER", "dd"), ("ACTION", "raw"), ("START", 34),
         ("SECTORS", 2014), ("USED_BYTES", 1031168), ("STREAM_FILE", "p5-BIOS.raw.pc.xz"), ("STREAM_BYTES", 58560),
         ("STREAM_SHA256", "d90e8378175e1ebfe0c5840d319271c7a699ab0e4c33f9c6f01589eeb2844e02"), ("COMP", "xz")],
    ]
    out = hdr
    for pairs in blocks:
        out += f"UNITOTEM_PART={pairs[0][1]}\n" + "".join(f"UNITOTEM_PART_{k}={v}\n" for k, v in pairs[1:]) + "\n"
    return out


def write_set(td, name, text):
    d = os.path.join(td, name)
    os.makedirs(d)
    open(os.path.join(d, "parts.manifest"), "w").write(text)
    return d


LOAD_PARTS = fn(RD_TEXT, "load_parts")
READ_KV = fn(LIB_TEXT, "read_kv_block")
LOOP_M = re.search(r"^    local -A block\n.*?^    done 9< \"\$\{OPT_PARTS\}/parts\.manifest\"\n", RD_TEXT, re.S | re.M)
check("harness: the manifest loop of run_ota_sequence is found in deploy/remote-deploy.sh", LOOP_M is not None)
LOOP_FN = "loop_fn() {\n" + (LOOP_M.group(0) if LOOP_M else "") + "}\n"

with tempfile.TemporaryDirectory() as td:
    # ---- 1. load_parts ----------------------------------------------------------------------------------------------------
    setdir = write_set(td, "set-a", manifest())
    harness = f'''set -u
log() {{ :; }}; warn() {{ :; }}; die() {{ echo "DIE: $*"; exit 1; }}
ARCH=amd64; FIRMWARE=bios; TRYBOOT_CAPABLE=0; DIR="{td}"; OPT_PARTS="{setdir}"
{LOAD_PARTS}
load_parts
echo "ROOT_A=$P_ROOT_PART BOOT=[$P_BOOT_PART] DATA=$P_DATA_PART BOOTFS=$P_BOOTFS_PART BIOS=$(part_num_for_label BIOS) LAYOUT=$P_LAYOUT"
'''
    r = sh(harness)
    check("load_parts accepts the A/B (layout 2) BIOS parts set", r.returncode == 0 and "DIE:" not in r.stdout, (r.stdout, r.stderr))
    check("load_parts resolves ROOT_A=2 DATA=4 BOOTFS=1 and exposes layout 2", "ROOT_A=2" in r.stdout and "DATA=4" in r.stdout and "BOOTFS=1" in r.stdout and "LAYOUT=2" in r.stdout, r.stdout)
    check("the BIOS partition number is 5 (read from the manifest, the partition of the ef02 entry)", "BIOS=5" in r.stdout, r.stdout)
    # the partition number follows the manifest, not a constant
    setdir7 = write_set(td, "set-7", manifest(bios_num=7))
    r7 = sh(harness.replace(setdir, setdir7))
    check("the BIOS partition number follows the manifest (7 when the manifest says 7)", "BIOS=7" in r7.stdout, (r7.stdout, r7.stderr))
    # layout 1 is refused
    setdir1 = write_set(td, "set-l1", manifest(layout=1))
    r1 = sh(harness.replace(setdir, setdir1))
    check("a layout 1 (non-A/B) parts set is refused by load_parts", r1.returncode != 0 and "not A/B" in r1.stdout and "BIOS=" not in r1.stdout, (r1.stdout, r1.stderr))
    # no parts set at all
    r0 = sh(harness.replace(setdir, os.path.join(td, "no-such-set")))
    check("a missing parts set directory is refused", r0.returncode != 0 and "DIE:" in r0.stdout, (r0.stdout, r0.stderr))

    # ---- 2. manifest loop: raw/dd block -> restore-part --cloner dd --------------------------------------------------------
    d = os.path.join(td, "loop")
    os.makedirs(d)
    loop_h = f'''set -u
log() {{ :; }}; warn() {{ :; }}; die() {{ echo "DIE: $*"; exit 1; }}
host=root@10.0.0.9; disk=/dev/sda; hostip=10.0.0.1; OPT_PORT=9000; OPT_PARTS="{setdir}"; OPT_WIPE_DATA=0
declare -A P=([HAVE_DATA]=1)
ota_ssh() {{ printf '%s\\n' "$2" >> "{d}/ssh.log"; }}
serve_file_once() {{ echo "$1" >> "{d}/serve.log"; echo 999999; }}
wait_port_bound() {{ return 0; }}
{READ_KV}
{LOOP_FN}
loop_fn
echo LOOP-DONE
'''
    r = sh(loop_h)
    ssh = open(os.path.join(d, "ssh.log")).read().splitlines() if os.path.exists(os.path.join(d, "ssh.log")) else []
    served = open(os.path.join(d, "serve.log")).read().splitlines() if os.path.exists(os.path.join(d, "serve.log")) else []
    check("manifest loop runs to the end over the fixture set", r.returncode == 0 and "LOOP-DONE" in r.stdout, (r.stdout, r.stderr))
    check("BIOS (ACTION raw) is sent as restore-part with --cloner dd and --comp xz",
          "unitotem-ota-engine restore-part --disk '/dev/sda' --part '5' --cloner 'dd' --comp 'xz' --used-bytes '1031168' --data-host '10.0.0.1' --data-port '9000'" in ssh, ssh)
    check("BIOS stream is the one served over the data channel", any(s.endswith("/p5-BIOS.raw.pc.xz") for s in served), served)
    check("ROOT_A (restore) still goes to restore-part with --cloner extfs",
          any("--part '2' --cloner 'extfs'" in s for s in ssh), ssh)
    check("ROOT_B (format) and DATA (preserve) keep their own commands", any(s.startswith("unitotem-ota-engine format-part") and "--part '3'" in s for s in ssh)
          and any("data-op" in s and "--part '4'" in s and "--op preserve" in s for s in ssh), ssh)
    check("EFI (filecopy) is not streamed by restore-part", not any("--part '1'" in s for s in ssh) and not any("p1-EFI" in s for s in served), (ssh, served))
    check("the BIOS restore-part is sent exactly once", sum("--part '5'" in s for s in ssh) == 1, ssh)

    # ---- 3. cmd_restore_part, dd branch ----------------------------------------------------------------------------------
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

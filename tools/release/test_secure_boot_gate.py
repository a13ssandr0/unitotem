#!/usr/bin/env python3
"""Host-side test of the Secure Boot logic of deploy/remote-deploy.sh, with no target: the functions/snippets are cut out of the
real script text (so the test follows the code), run in a bash harness with fake inputs, and judged on exit status, the resulting
SB_MODE and the text printed. Covers: the od-based parsing of the SecureBoot EFI variable (probe snippet), and secure_boot_gate for
SB=0/1/unknown, every --secure-boot value, non-interactive refusal, the interactive 1/2/3 choice, an already-UniTotem target and the
A/B-layout requirement. What it does NOT prove: anything about a real firmware (see work/sb-test/REPORT.md for the QEMU/OVMF runs).

  python3 tools/release/test_secure_boot_gate.py
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPT = open(os.path.join(ROOT, "deploy/remote-deploy.sh")).read()
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def has(text, pattern):
    """Case-insensitive regex search; the patterns accept the wording of the deploy script's messages."""
    return re.search(pattern, text, re.I) is not None


# ---- cut the code under test out of the script -------------------------------------------------------------------------
m = re.search(r"^secure_boot_gate\(\) \{\n.*?^\}\n", SCRIPT, re.S | re.M)
assert m, "secure_boot_gate not found in deploy/remote-deploy.sh"
GATE = m.group(0)
m = re.search(r"^SBV=.*?^echo \"SECUREBOOT: \$SB\"\n", SCRIPT, re.S | re.M)
assert m, "the SecureBoot probe snippet not found in deploy/remote-deploy.sh"
PROBE = m.group(0)


def probe(content):
    """Run the probe snippet against a fake efivar file (None = file absent). Returns the 'SECUREBOOT: x' line."""
    with tempfile.TemporaryDirectory() as td:
        f = os.path.join(td, "SecureBoot-var")
        if content is not None: open(f, "wb").write(content)
        snippet = re.sub(r"^SBV=.*$", "SBV=" + f, PROBE, count=1, flags=re.M)
        r = subprocess.run(["bash", "-c", "set -u\n" + snippet], capture_output=True, text=True)
        return r.stdout.strip(), r.returncode


def gate(sb, have=0, layout=2, flag="", yes=0, stdin="", arch="amd64", fw="uefi"):
    pre = f'''set -euo pipefail
log() {{ echo ">>> $*"; }}; warn() {{ echo "!!! $*" >&2; }}; die() {{ echo "*** $*" >&2; exit 1; }}
declare -A P; P[SECUREBOOT]="{sb}"; P[HAVE_UNITOTEM]={have}
ARCH={arch}; FIRMWARE={fw}; P_LAYOUT={layout}; OPT_SECURE_BOOT="{flag}"; OPT_YES={yes}; SB_MODE=""
'''
    code = pre + GATE + '\nsecure_boot_gate\necho "SB_MODE=[$SB_MODE] OPT=[$OPT_SECURE_BOOT]"\n'
    r = subprocess.run(["bash", "-c", code], input=stdin, capture_output=True, text=True, timeout=20)
    return r.returncode, r.stdout, r.stderr


# ---- D1: parsing of the SecureBoot variable ----------------------------------------------------------------------------
attrs = bytes([6, 0, 0, 0])      # EFI_VARIABLE_BOOTSERVICE_ACCESS | RUNTIME_ACCESS, as the kernel exposes it
check("probe: attributes + 1 -> SECUREBOOT: 1", probe(attrs + b"\x01") == ("SECUREBOOT: 1", 0), probe(attrs + b"\x01"))
check("probe: attributes + 0 -> SECUREBOOT: 0", probe(attrs + b"\x00") == ("SECUREBOOT: 0", 0), probe(attrs + b"\x00"))
check("probe: 7 attribute-like byte 0x07 + 1 still reads byte 5", probe(bytes([7, 0, 0, 0]) + b"\x01")[0] == "SECUREBOOT: 1")
check("probe: a value other than 0/1 is 'unknown', never guessed", probe(attrs + b"\x02")[0] == "SECUREBOOT: unknown", probe(attrs + b"\x02"))
check("probe: truncated file (attributes only) is 'unknown'", probe(attrs)[0] == "SECUREBOOT: unknown", probe(attrs))
check("probe: empty file is 'unknown'", probe(b"")[0] == "SECUREBOOT: unknown")
check("probe: absent variable (legacy BIOS) is 'unknown', exit 0", probe(None) == ("SECUREBOOT: unknown", 0), probe(None))

# ---- D2: secure_boot_gate ----------------------------------------------------------------------------------------------
rc, out, err = gate("0")
check("SB=0: nothing to decide", rc == 0 and "SB_MODE=[]" in out and err == "", (rc, out, err))
rc, out, err = gate("0", flag="shim")
check("SB=0 with --secure-boot shim: flag ignored with a warning", rc == 0 and "SB_MODE=[]" in out and has(err, r"ignor"), (rc, out, err))
rc, out, err = gate("unknown", yes=1)
check("unknown state: warns and proceeds as if off", rc == 0 and "SB_MODE=[]" in out and has(err, r"not detect|undetect|cannot be (detected|determined)|unknown"), (rc, out, err))
rc, out, err = gate("1", flag="shim")
check("SB=1 --secure-boot shim (A/B): SB_MODE=shim", rc == 0 and "SB_MODE=[shim]" in out, (rc, out, err))
rc, out, err = gate("1", flag="noshim")
check("SB=1 --secure-boot noshim: SB_MODE=noshim + physical-intervention warning", rc == 0 and "SB_MODE=[noshim]" in out and has(err, r"intervento fisico|physical"), (rc, out, err))
rc, out, err = gate("1", flag="abort")
check("SB=1 --secure-boot abort: dies", rc != 0 and has(err, r"annullato|abort|cancel") and "SB_MODE" not in out, (rc, out, err))
rc, out, err = gate("1", yes=1)
check("SB=1 non-interactive (--yes) without the flag: dies, asking for an explicit choice", rc != 0 and "--secure-boot" in err and "SB_MODE" not in out, (rc, out, err))
rc, out, err = gate("1", layout=1, flag="shim")
check("non-A/B parts set is refused in load_parts, before the Secure Boot gate", SCRIPT.index("\n    load_parts\n") < SCRIPT.index("\n    secure_boot_gate\n") and has(SCRIPT[SCRIPT.index("load_parts() {"):SCRIPT.index("\n}\n", SCRIPT.index("load_parts() {"))], r'P_LAYOUT" = 2 \] \|\| die'))
rc, out, err = gate("1", layout=1, flag="noshim")
check("SB=1 noshim works with any layout", rc == 0 and "SB_MODE=[noshim]" in out, (rc, out, err))
rc, out, err = gate("1", have=1)
check("SB=1 on a target that already is UniTotem (A/B): keeps shim, no question", rc == 0 and "SB_MODE=[shim]" in out and not has(out, r"Scelta|Choice"), (rc, out, err))
rc, out, err = gate("1", have=1, yes=1)
check("SB=1 already UniTotem, non-interactive: keeps shim without the flag", rc == 0 and "SB_MODE=[shim]" in out, (rc, out, err))
rc, out, err = gate("1", have=1, layout=1, yes=1)
rc, out, err = gate("1", have=1, flag="noshim")
check("SB=1 already UniTotem + explicit noshim: the explicit choice wins", rc == 0 and "SB_MODE=[noshim]" in out, (rc, out, err))
for choice, exp in (("1", "shim"), ("2", "noshim")):
    rc, out, err = gate("1", stdin=choice + "\n")
    check(f"SB=1 interactive, answer {choice}: SB_MODE={exp}", rc == 0 and f"SB_MODE=[{exp}]" in out and has(out, r"INTERVENTO FISICO|PHYSICAL"), (rc, out, err))
for choice in ("3", "", "x"):
    rc, out, err = gate("1", stdin=choice + "\n")
    check(f"SB=1 interactive, answer {choice!r}: aborts (anything but 1/2 is a no)", rc != 0 and has(err, r"annullato|abort|cancel"), (rc, out, err))
rc, out, err = gate("1", stdin="")
check("SB=1 interactive, stdin closed (EOF): does not proceed", rc != 0 and "SB_MODE=[shim]" not in out and "SB_MODE=[noshim]" not in out, (rc, out, err))
rc, out, err = gate("1", arch="arm64", fw="rpi", yes=1)
check("arm64/rpi: the gate is a no-op even if SB were reported", rc == 0 and "SB_MODE=[]" in out, (rc, out, err))
rc, out, err = gate("1", fw="bios", yes=1)
check("amd64/legacy BIOS: the gate is a no-op", rc == 0 and "SB_MODE=[]" in out, (rc, out, err))

# ---- D3: wiring ----------------------------------------------------------------------------------------------------------
check("populate_bootfs_step passes --secure-boot shim only when SB_MODE=shim", '[ "$SB_MODE" = shim ] && lay="$lay --secure-boot shim"' in SCRIPT)
check("the gate runs before the changes gate", SCRIPT.index("\n    secure_boot_gate\n") < SCRIPT.index("\n    changes_gate\n"))
i = SCRIPT.index('if [ "$SB_MODE" = noshim ]; then\n        echo ""'); j = re.search(r"Waiting for \$\{target_ip\} to answer on the new system", SCRIPT).start()
check("noshim: the big warning + return come BEFORE the 10-minute wait for the target", i < j and "return 0" in SCRIPT[i:j])

print(f"== {ok + fail} checks, {fail} failed")
sys.exit(1 if fail else 0)

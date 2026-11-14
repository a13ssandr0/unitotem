#!/usr/bin/env python3
"""Host-side test of the Secure Boot logic of deploy/remote-deploy.sh, with no target: the functions/snippets are cut out of the
real script text (so the test follows the code), run in a bash harness with fake inputs, and judged on exit status and the text
printed. Covers: the od-based parsing of the SecureBoot EFI variable (probe snippet), secure_boot_note (the image carries the signed
chain as its loader, so there is nothing to choose: only the state is reported) and the wiring (no --secure-boot option, no SB_MODE).
What it does NOT prove: anything about a real firmware (see boot.md for the QEMU/OVMF runs).

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
m = re.search(r"^secure_boot_note\(\) \{\n.*?^\}\n", SCRIPT, re.S | re.M)
assert m, "secure_boot_note not found in deploy/remote-deploy.sh"
NOTE = m.group(0)
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


def note(sb, arch="amd64", fw="uefi"):
    pre = f'''set -euo pipefail
log() {{ echo ">>> $*"; }}; warn() {{ echo "!!! $*" >&2; }}; die() {{ echo "*** $*" >&2; exit 1; }}
declare -A P; P[SECUREBOOT]="{sb}"
ARCH={arch}; FIRMWARE={fw}
'''
    r = subprocess.run(["bash", "-c", pre + NOTE + "\nsecure_boot_note\n"], capture_output=True, text=True, timeout=20)
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

# ---- D2: secure_boot_note ----------------------------------------------------------------------------------------------
rc, out, err = note("0")
check("SB=0: nothing printed", rc == 0 and out == "" and err == "", (rc, out, err))
rc, out, err = note("1")
check("SB=1: reported, with the NVIDIA MOK step, never a question or a refusal", rc == 0 and has(out, r"Secure Boot is active") and has(out, r"MOK") and err == "", (rc, out, err))
rc, out, err = note("unknown")
check("unknown state: a warning that the chain boots either way, exit 0", rc == 0 and has(err, r"cannot be detected") and has(err, r"on or off"), (rc, out, err))
rc, out, err = note("1", arch="arm64", fw="rpi")
check("arm64/rpi: a no-op even if SB were reported", rc == 0 and out == "" and err == "", (rc, out, err))
rc, out, err = note("1", fw="bios")
check("amd64/legacy BIOS: a no-op", rc == 0 and out == "" and err == "", (rc, out, err))

# ---- D3: wiring ----------------------------------------------------------------------------------------------------------
check("no --secure-boot option and no shim/noshim mode left in the deploy script", "--secure-boot" not in SCRIPT and "SB_MODE" not in SCRIPT and "OPT_SECURE_BOOT" not in SCRIPT and "secure_boot_gate" not in SCRIPT)
check("the note runs before the changes gate", SCRIPT.index("\n    secure_boot_note\n") < SCRIPT.index("\n    changes_gate\n"))
check("the engine has no activation step either (the chain is part of the ESP content)", "secure-boot" not in open(os.path.join(ROOT, "deploy/ota-engine.sh")).read())

print(f"== {ok + fail} checks, {fail} failed")
sys.exit(1 if fail else 0)

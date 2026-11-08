#!/usr/bin/env python3
"""Host-side test of the recovery-file source of the deploy write-bootfile step (deploy/remote-deploy.sh):
recovery_from_parts takes the recovery kernel, initrd and recovery.sha256 from the parts set's boot tarball, verifies
them against the tarball's recovery.sha256, and falls back to the host copies in deploy/<arch>/ with a warning when the
tarball lacks a member. Functions are cut out of the real script text and run under bash. Temporary directories only;
no device, no /etc, no /run, no network.

  PYTHONDONTWRITEBYTECODE=1 python3 tools/release/test_deploy_recovery_source.py
"""
import hashlib, io, lzma, os, re, subprocess, sys, tarfile, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RD_TEXT = open(os.path.join(ROOT, "deploy/remote-deploy.sh")).read()
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def fn(text, name):
    """Source text of the shell function NAME (block form, closing brace in column 0)."""
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.S | re.M)
    if not m:
        raise SystemExit("FAIL: function %s not found in deploy/remote-deploy.sh" % name)
    return m.group(0)


def sha(data):
    return hashlib.sha256(data).hexdigest()


# Payloads: the tarball copies differ from the host copies, so a result shows which source was used.
KERNEL_TB, INITRD_TB = b"tarball-kernel\x00" * 300, b"tarball-initrd\x01" * 500
KERNEL_HOST, INITRD_HOST = b"host-kernel" * 40, b"host-initrd" * 60
SHA_LEVEL = "# unitotem-recovery-level: 20261019055632\n"


def make_tar(path, members):
    """members: list of (stored name, bytes). Names are stored verbatim (./ prefix kept)."""
    with lzma.open(path, "wb") as xz:
        with tarfile.open(fileobj=xz, mode="w") as tf:
            for name, data in members:
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))


def sha_file(lines):
    return "".join(f"{h}  {n}\n" for h, n in lines).encode()


def run_case(td, tag, arch, members, tar_at=True, host=True):
    """Build a parts dir, a host deploy dir and an output dir; call recovery_from_parts; return (rc, stdout, stderr, out)."""
    base = os.path.join(td, tag)
    parts = os.path.join(base, "parts")
    out = os.path.join(base, "out")
    dep = os.path.join(base, "deploy", arch)
    os.makedirs(parts); os.makedirs(out); os.makedirs(dep)
    stream_name = "p1-EFI.bootfs.tar.xz" if arch == "amd64" else "p1-FIRMWARE.bootfs.tar.xz"
    manifest_stream = stream_name
    open(os.path.join(parts, "parts.manifest"), "w").write(
        "UNITOTEM_PARTS_PROTO=1\nUNITOTEM_LAYOUT=2\nUNITOTEM_PART=1\nUNITOTEM_PART_LABEL=%s\n"
        "UNITOTEM_PART_FSTYPE=vfat\nUNITOTEM_PART_ACTION=filecopy\nUNITOTEM_PART_STREAM_FILE=%s\n\n"
        "UNITOTEM_PART=2\nUNITOTEM_PART_LABEL=ROOT_A\nUNITOTEM_PART_STREAM_FILE=p2-ROOT_A.ext4.pc.xz\n"
        % ("EFI" if arch == "amd64" else "FIRMWARE", manifest_stream))
    if tar_at:
        make_tar(os.path.join(parts, stream_name), members)
    if host:
        open(os.path.join(dep, f"recovery-vmlinuz-{arch}"), "wb").write(KERNEL_HOST)
        open(os.path.join(dep, f"recovery-initrd-{arch}.img"), "wb").write(INITRD_HOST)
    harness = f'''set -euo pipefail
warn() {{ echo "WARN: $*" >&2; }}
DIR="{base}"
{fn(RD_TEXT, "recovery_member")}
{fn(RD_TEXT, "recovery_extract")}
{fn(RD_TEXT, "recovery_from_parts")}
rc=0
recovery_from_parts "{parts}" "{arch}" "{out}" || rc=$?
echo "RC=$rc"
'''
    r = subprocess.run(["bash", "-c", harness], capture_output=True, text=True, timeout=120)
    # stdout: the status word, then RC=n; anything else on stdout is a violation of the contract
    lines = r.stdout.splitlines()
    status = lines[0] if lines else ""
    rc_line = lines[-1] if lines else ""
    return r, status, rc_line, out, dep


def read(path):
    return open(path, "rb").read() if os.path.exists(path) else None


with tempfile.TemporaryDirectory() as td:
    # ---- 1. amd64, tarball with unitotem/ prefix: parts used, sha verified -----------------------------------------------
    sums = sha_file([(sha(KERNEL_TB), "recovery-vmlinuz"), (sha(INITRD_TB), "recovery-initrd.img")])
    sums_full = (SHA_LEVEL.encode() + sums)
    members = [("unitotem/recovery-vmlinuz", KERNEL_TB), ("unitotem/recovery-initrd.img", INITRD_TB),
               ("unitotem/recovery.sha256", sums_full), ("unitotem/other.bin", b"x")]
    r, st, rc, out, dep = run_case(td, "amd64-ok", "amd64", members)
    check("amd64: tarball recovery files are used (status parts, rc 0)", st == "parts" and rc == "RC=0", (r.stdout, r.stderr))
    check("amd64: kernel written under the FAT name recovery-vmlinuz from the tarball",
          read(os.path.join(out, "recovery-vmlinuz")) == KERNEL_TB)
    check("amd64: initrd written as recovery-initrd.img from the tarball", read(os.path.join(out, "recovery-initrd.img")) == INITRD_TB)
    check("amd64: recovery.sha256 copied verbatim (level line kept)", read(os.path.join(out, "recovery.sha256")) == sums_full)
    check("amd64: stdout is exactly the status word and rc line", r.stdout == "parts\nRC=0\n", r.stdout)
    check("amd64: no warning on the success path", "WARN" not in r.stderr, r.stderr)

    # ---- 2. amd64 members stored with ./ prefix ----------------------------------------------------------------------------
    members_dot = [("./unitotem/recovery-vmlinuz", KERNEL_TB), ("./unitotem/recovery-initrd.img", INITRD_TB),
                   ("./unitotem/recovery.sha256", sums_full)]
    r, st, rc, out, dep = run_case(td, "amd64-dot", "amd64", members_dot)
    check("amd64 ./ prefixed members: parts used and verified", st == "parts" and rc == "RC=0", (r.stdout, r.stderr))
    check("amd64 ./ prefixed members: kernel bytes are the tarball's", read(os.path.join(out, "recovery-vmlinuz")) == KERNEL_TB)

    # ---- 3. arm64, names at the top of the tarball (recovery8.img) ----------------------------------------------------------
    sums_a = sha_file([(sha(KERNEL_TB), "recovery8.img"), (sha(INITRD_TB), "recovery-initrd.img")])
    members_a = [("recovery8.img", KERNEL_TB), ("recovery-initrd.img", INITRD_TB), ("recovery.sha256", sums_a)]
    r, st, rc, out, dep = run_case(td, "arm64-ok", "arm64", members_a)
    check("arm64: top-level members used (status parts, rc 0)", st == "parts" and rc == "RC=0", (r.stdout, r.stderr))
    check("arm64: kernel written as recovery8.img from the tarball", read(os.path.join(out, "recovery8.img")) == KERNEL_TB)
    check("arm64: initrd written as recovery-initrd.img", read(os.path.join(out, "recovery-initrd.img")) == INITRD_TB)
    check("arm64: no recovery-vmlinuz written", not os.path.exists(os.path.join(out, "recovery-vmlinuz")))

    # ---- 4. arm64 with ./ prefix ---------------------------------------------------------------------------------------------
    members_ad = [("./recovery8.img", KERNEL_TB), ("./recovery-initrd.img", INITRD_TB), ("./recovery.sha256", sums_a)]
    r, st, rc, out, dep = run_case(td, "arm64-dot", "arm64", members_ad)
    check("arm64 ./ prefixed members: parts used and verified", st == "parts" and rc == "RC=0", (r.stdout, r.stderr))

    # ---- 5. sha mismatch: refused, rc 1, status refused -----------------------------------------------------------------------
    bad = sha_file([("0" * 64, "recovery-vmlinuz"), (sha(INITRD_TB), "recovery-initrd.img")])
    members_bad = [("unitotem/recovery-vmlinuz", KERNEL_TB), ("unitotem/recovery-initrd.img", INITRD_TB),
                   ("unitotem/recovery.sha256", bad)]
    r, st, rc, out, dep = run_case(td, "amd64-badsha", "amd64", members_bad)
    check("sha mismatch in the tarball: refused with rc 1", st == "refused" and r.returncode == 0 and rc == "RC=1", (r.stdout, r.stderr))
    check("sha mismatch: warning names the file on stderr", "recovery-vmlinuz does not match" in r.stderr, r.stderr)
    check("sha mismatch: host copies are NOT used", read(os.path.join(out, "recovery-vmlinuz")) != KERNEL_HOST)

    # initrd content differs from its line (the kernel line is right): refused too
    tamp = sha_file([(sha(KERNEL_TB), "recovery-vmlinuz"), (sha(b"other"), "recovery-initrd.img")])
    r, st, rc, out, dep = run_case(td, "amd64-badinitrd", "amd64", [
        ("unitotem/recovery-vmlinuz", KERNEL_TB), ("unitotem/recovery-initrd.img", INITRD_TB),
        ("unitotem/recovery.sha256", tamp)])
    check("sha mismatch on the initrd line only: refused", st == "refused" and rc == "RC=1", (r.stdout, r.stderr))

    # a checksum line missing for a present file: refused (malformed tarball, not a missing member)
    nol = sha_file([(sha(KERNEL_TB), "recovery-vmlinuz")])
    r, st, rc, out, dep = run_case(td, "amd64-nolines", "amd64", [
        ("unitotem/recovery-vmlinuz", KERNEL_TB), ("unitotem/recovery-initrd.img", INITRD_TB),
        ("unitotem/recovery.sha256", nol)])
    check("a file without a checksum line in the tarball: refused", st == "refused" and rc == "RC=1", (r.stdout, r.stderr))

    # ---- 6. tarball lacks the members: host fallback with a warning ----------------------------------------------------------
    r, st, rc, out, dep = run_case(td, "amd64-missing", "amd64", [("unitotem/other.bin", b"x")])
    check("tarball without recovery members: host fallback (status host, rc 0)", st == "host" and rc == "RC=0", (r.stdout, r.stderr))
    check("host fallback: warning on stderr", "WARN: the parts set's boot tarball has no recovery" in r.stderr, r.stderr)
    check("host fallback: kernel and initrd are the host copies", read(os.path.join(out, "recovery-vmlinuz")) == KERNEL_HOST
          and read(os.path.join(out, "recovery-initrd.img")) == INITRD_HOST)
    hsum = sha_file([(sha(KERNEL_HOST), "recovery-vmlinuz"), (sha(INITRD_HOST), "recovery-initrd.img")])
    check("host fallback: recovery.sha256 describes the files written", read(os.path.join(out, "recovery.sha256")) == hsum,
          read(os.path.join(out, "recovery.sha256")))
    check("host fallback: stdout is only the status word and rc line", r.stdout == "host\nRC=0\n", r.stdout)

    # tarball has the kernel and initrd but no recovery.sha256: host fallback too
    r, st, rc, out, dep = run_case(td, "amd64-nosha", "amd64", [
        ("unitotem/recovery-vmlinuz", KERNEL_TB), ("unitotem/recovery-initrd.img", INITRD_TB)])
    check("tarball without recovery.sha256: host fallback with warning", st == "host" and "WARN" in r.stderr
          and read(os.path.join(out, "recovery-vmlinuz")) == KERNEL_HOST, (r.stdout, r.stderr))

    # arm64 tarball with amd64-style names (unitotem/ prefix): not a match, host fallback
    r, st, rc, out, dep = run_case(td, "arm64-wrongnames", "arm64", members)
    check("arm64 with unitotem/ names: no match, host fallback", st == "host" and rc == "RC=0", (r.stdout, r.stderr))

    # ---- 7. no tarball at all (manifest names a stream file that is absent) ------------------------------------------------
    r, st, rc, out, dep = run_case(td, "amd64-notar", "amd64", members, tar_at=False)
    check("stream file absent: host fallback with warning", st == "host" and "WARN" in r.stderr, (r.stdout, r.stderr))

    # ---- 8. no host copy and no tarball member: missing, rc 1, nothing half-written as a parts file ------------------------
    r, st, rc, out, dep = run_case(td, "amd64-nohost", "amd64", [("unitotem/other.bin", b"x")], host=False)
    check("no tarball member and no host copy: status missing, rc 1", st == "missing" and rc == "RC=1", (r.stdout, r.stderr))

    # ---- 9. the parts dir itself absent ----------------------------------------------------------------------------------------
    harness = f'''set -euo pipefail
warn() {{ echo "WARN: $*" >&2; }}
DIR="{os.path.join(td, 'absent')}"
mkdir -p "$DIR/deploy/amd64" "{os.path.join(td, 'absent-out')}"
printf k > "$DIR/deploy/amd64/recovery-vmlinuz-amd64"; printf i > "$DIR/deploy/amd64/recovery-initrd-amd64.img"
{fn(RD_TEXT, "recovery_member")}
{fn(RD_TEXT, "recovery_extract")}
{fn(RD_TEXT, "recovery_from_parts")}
recovery_from_parts "{os.path.join(td, 'no-such-parts')}" amd64 "{os.path.join(td, 'absent-out')}"
'''
    r = subprocess.run(["bash", "-c", harness], capture_output=True, text=True, timeout=60)
    check("parts dir absent: host fallback, status host", r.returncode == 0 and r.stdout == "host\n" and "WARN" in r.stderr,
          (r.stdout, r.stderr))

    # ---- 10. recovery_member matches names with and without ./ and nothing else ----------------------------------------------
    harness = f'''set -euo pipefail
{fn(RD_TEXT, "recovery_member")}
list=$'./unitotem/recovery-vmlinuz\\nunitotem/recovery-initrd.img\\n./recovery8.img'
echo "A=$(recovery_member "$list" unitotem/recovery-vmlinuz)"
echo "B=$(recovery_member "$list" unitotem/recovery-initrd.img)"
echo "C=$(recovery_member "$list" recovery8.img)"
echo "D=$(recovery_member "$list" recovery)"
'''
    r = subprocess.run(["bash", "-c", harness], capture_output=True, text=True, timeout=60)
    check("recovery_member: stored name returned as stored (./ kept), prefix match exact only",
          "A=./unitotem/recovery-vmlinuz" in r.stdout and "B=unitotem/recovery-initrd.img" in r.stdout
          and "C=./recovery8.img" in r.stdout and "D=\n" in r.stdout, (r.stdout, r.stderr))

print("\n%d passed, %d failed" % (ok, fail))
sys.exit(1 if fail else 0)

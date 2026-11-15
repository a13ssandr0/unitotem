#!/bin/bash
# Tests of unitotem/ninitrd/stage.py (class Stage): library closure against ldd on the host (same-arch binaries),
# symlink chains copied into DEST, symlinks inside ROOT resolved against ROOT, return codes, setuid bits,
# and an arm64 run against the stage-1 rootfs (readelf only, no target binary is executed).
# Fixtures live in a tempfile directory removed by the script. Nothing outside it is written.
#   bash tools/release/test_native_initrd_stage.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

exec python3 -I - "$REPO/unitotem/ninitrd" "$REPO/work/native-initrd/ninitrd-rootfs" <<'PY'
import os
import re
import stat
import subprocess
import sys
import tempfile

NINITRD, ROOTFS = sys.argv[1], sys.argv[2]
sys.dont_write_bytecode = True  # no __pycache__ in the repository
sys.path.insert(0, NINITRD)
from stage import Stage  # noqa: E402

LDD_ENV = {k: v for k, v in os.environ.items() if k not in ("LD_LIBRARY_PATH", "LD_PRELOAD")}
LDD_ENV["LC_ALL"] = "C"
RE_LDD = re.compile(r"(?:=>\s+|^\s*)(/\S+)\s+\(0x")

failures = []
warnings = []


def check(name, ok, detail=""):
    if ok:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name}: {detail}")
        failures.append(name)


def warn(msg):
    warnings.append(msg)
    print(msg, file=sys.stderr)


def ldd_real(binary):
    out = subprocess.run(["ldd", binary], env=LDD_ENV, capture_output=True, text=True, check=True).stdout
    paths = set()
    for line in out.splitlines():
        m = RE_LDD.search(line)
        if m:
            paths.add(os.path.realpath(m.group(1)))
    return paths


def stage_for(root, dest, arch, warn_fn=warn):
    return Stage(root, dest, arch, "test-kver", warn=warn_fn)


with tempfile.TemporaryDirectory(prefix="unitotem-native-initrd-stage-") as tmp:
    # 1. Host closure equals ldd, for three same-arch binaries
    for i, src in enumerate(["/usr/bin/bash", "/usr/bin/ls", "/usr/bin/ssh"]):
        del warnings[:]
        dest = os.path.join(tmp, f"host{i}")
        st = stage_for("/", dest, "amd64")
        ours = {st.readlink_f(p) for p in st.libraries(src)}
        ref = ldd_real(src)
        check(f"host closure {src} equals ldd", ours == ref,
              f"only stage: {sorted(ours - ref)} only ldd: {sorted(ref - ours)}")
        check(f"host closure {src} no warnings", not warnings, str(warnings))
        print(f"     {src}: {len(ref)} libraries")

    # 2. copy_exec of /usr/bin/ls: symlink chain and every library copied at its real path
    dest = os.path.join(tmp, "ls")
    st = stage_for("/", dest, "amd64")
    rc = st.copy_exec("/usr/bin/ls")
    real_ls = os.path.realpath("/usr/bin/ls")
    rel = os.path.relpath(real_ls, "/usr/bin")
    link = os.path.join(dest, "usr/bin/ls")
    check("copy_exec ls returns 0", rc == 0, f"rc={rc}")
    check("ls symlink is relative to the real file",
          os.path.islink(link) and os.readlink(link) == rel,
          f"readlink={os.readlink(link) if os.path.islink(link) else None} expected={rel}")
    real_dst = os.path.join(dest, real_ls.lstrip("/"))
    check("ls real file copied at its resolved path", os.path.isfile(real_dst), real_dst)
    if os.path.isfile(real_dst):
        s_src, s_dst = os.stat(real_ls), os.stat(real_dst)
        check("ls mode and mtime preserved",
              stat.S_IMODE(s_src.st_mode) == stat.S_IMODE(s_dst.st_mode) and int(s_src.st_mtime) == int(s_dst.st_mtime),
              f"{oct(stat.S_IMODE(s_src.st_mode))} {oct(stat.S_IMODE(s_dst.st_mode))}")
    missing = [p for p in ldd_real("/usr/bin/ls")
               if not os.path.isfile(os.path.join(dest, p.lstrip("/")))]
    check("ls libraries present in DEST", not missing, str(missing))

    # 3. Symlink chain /bin/sh -> dash (usr-merge /bin, then relative link)
    dest = os.path.join(tmp, "sh")
    st = stage_for("/", dest, "amd64")
    rc = st.copy_file("binary", "/bin/sh")
    check("copy_file /bin/sh returns 0", rc == 0, f"rc={rc}")
    real_sh = os.path.realpath("/usr/bin/sh")
    sh_link = os.path.join(dest, "usr/bin/sh")
    check("/bin/sh chain: usr/bin/sh is a relative link",
          os.path.islink(sh_link) and os.readlink(sh_link) == os.path.relpath(real_sh, "/usr/bin"),
          str(os.path.islink(sh_link) and os.readlink(sh_link)))
    check("/bin/sh chain: real file copied",
          os.path.isfile(os.path.join(dest, real_sh.lstrip("/"))), real_sh)
    check("copy_file again returns 1 (already present)", st.copy_file("binary", "/bin/sh") == 1)
    check("copy_file missing source returns 2", st.copy_file("binary", "/usr/bin/ninitrd-no-such-file") == 2)

    # 4. Symlinks inside ROOT resolve against ROOT, not against the host
    root = os.path.join(tmp, "root")
    os.makedirs(os.path.join(root, "usr/bin"))
    os.symlink("usr/bin", os.path.join(root, "bin"))
    with open(os.path.join(root, "usr/bin/ninitrd-stage-probe"), "w") as fh:
        fh.write("probe\n")
    os.chmod(os.path.join(root, "usr/bin/ninitrd-stage-probe"), 0o755)
    os.symlink("/usr/bin/ninitrd-stage-probe", os.path.join(root, "usr/bin/link"))
    with open(os.path.join(root, "usr/bin/true"), "w") as fh:
        fh.write("root-true\n")
    os.symlink("/usr/bin/true", os.path.join(root, "usr/bin/trap"))
    suid = os.path.join(root, "usr/bin/suid")
    with open(suid, "w") as fh:
        fh.write("suid\n")
    os.chmod(suid, 0o4755)

    dest = os.path.join(tmp, "rootdest")
    st = stage_for(root, dest, "amd64")
    check("ROOT absolute link: copy_file returns 0", st.copy_file("binary", "/usr/bin/link") == 0)
    check("ROOT absolute link: relative link in DEST",
          os.path.islink(os.path.join(dest, "usr/bin/link"))
          and os.readlink(os.path.join(dest, "usr/bin/link")) == "ninitrd-stage-probe")
    with open(os.path.join(dest, "usr/bin/ninitrd-stage-probe")) as fh:
        check("ROOT absolute link: target read from ROOT", fh.read() == "probe\n")
    check("ROOT trap link: copy_file returns 0", st.copy_file("binary", "/usr/bin/trap") == 0)
    with open(os.path.join(dest, "usr/bin/true")) as fh:
        check("ROOT trap link: host /usr/bin/true not used", fh.read() == "root-true\n")
    check("usr-merge /bin source copied to usr/bin",
          st.copy_file("binary", "/bin/ninitrd-stage-probe") == 1
          and os.path.isfile(os.path.join(dest, "usr/bin/ninitrd-stage-probe")))
    rc = st.copy_file("binary", "/usr/bin/suid")
    suid_mode = stat.S_IMODE(os.stat(os.path.join(dest, "usr/bin/suid")).st_mode) if rc == 0 else None
    check("setuid bit kept", rc == 0 and suid_mode == 0o4755, f"rc={rc} mode={suid_mode and oct(suid_mode)}")
    check("command_v resolves inside ROOT",
          st.command_v("ninitrd-stage-probe") == "/usr/bin/ninitrd-stage-probe"
          and st.command_v("link") == "/usr/bin/link"
          and st.command_v("ninitrd-no-such-cmd") is None,
          str(st.command_v("link")))
    check("triplet amd64", st.triplet == "x86_64-linux-gnu")

    # 5. arm64 stage-1 rootfs: readelf only, report the resolved libraries
    if not os.path.isdir(ROOTFS):
        print(f"SKIP arm64 rootfs: {ROOTFS} missing")
    else:
        for src in ["/usr/bin/bash", "/usr/sbin/dropbear", "/usr/bin/pv"]:
            del warnings[:]
            dest = os.path.join(tmp, "arm64-" + os.path.basename(src))
            st = stage_for(ROOTFS, dest, "arm64")
            rc = st.copy_exec(src)
            libs = st.libraries(src)
            check(f"arm64 copy_exec {src} returns 0", rc == 0, f"rc={rc}")
            check(f"arm64 {src} no unresolved library", not warnings, str(warnings))
            print(f"     {src} (triplet {st.triplet}):")
            for p in libs:
                real = st.readlink_f(p)
                in_rootfs = os.path.isfile(os.path.join(ROOTFS, real.lstrip("/")))
                in_dest = os.path.isfile(os.path.join(dest, real.lstrip("/")))
                print(f"       {p} -> {real} rootfs={in_rootfs} dest={in_dest}")
                check(f"arm64 {src} {real} exists in rootfs and DEST", in_rootfs and in_dest)

if failures:
    print(f"FAILED: {len(failures)} check(s)")
    sys.exit(1)
print("OK: all stage checks passed")
PY

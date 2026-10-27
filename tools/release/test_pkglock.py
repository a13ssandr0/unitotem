#!/usr/bin/env python3
"""Offline test of tools/pkglock.py: lock freeze/verify/prefs/snapshot and the parsing and classification behind `check` (no network).

  python3 tools/release/test_pkglock.py
"""
import importlib.util, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
spec = importlib.util.spec_from_file_location("pkglock", os.path.join(ROOT, "tools/pkglock.py"))
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


STATUS = """Package: libc6
Status: install ok installed
Architecture: amd64
Version: 2.41-12
Maintainer: GNU Libc Maintainers <debian-glibc@lists.debian.org>

Package: curl
Status: install ok installed
Architecture: amd64
Version: 8.14.1-2+deb13u7
Source: curl
Maintainer: Alessandro Ferrari <x@debian.org>

Package: removed-thing
Status: deinstall ok config-files
Architecture: all
Version: 1.0

Package: unitotem-manager
Status: install ok installed
Architecture: all
Version: 3.0.0~dev10
Maintainer: UniTotem <dev@unitotem.local>

Package: python3-fastapi-login
Status: install ok installed
Architecture: all
Version: 1.10.3-0unitotem1
Maintainer: UniTotem <dev@unitotem.local>
"""

POLICY = """curl:
  Installed: (none)
  Candidate: 8.14.1-2+deb13u8
  Version table:
     8.14.1-2+deb13u8 500
        500 http://security.debian.org/debian-security trixie-security/main amd64 Packages
     8.14.1-2+deb13u7 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
linux-image-amd64:
  Installed: (none)
  Candidate: 6.12.113-1
  Version table:
     7.2.11-1~bpo13+1 100
        100 http://deb.debian.org/debian trixie-backports/main amd64 Packages
     6.12.113-1 500
        500 http://security.debian.org/debian-security trixie-security/main amd64 Packages
libc6:
  Installed: (none)
  Candidate: 2.41-12
  Version table:
     2.41-12 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
"""

with tempfile.TemporaryDirectory() as td:
    st = os.path.join(td, "status"); open(st, "w").write(STATUS)
    pk = P.read_status(st)
    check("status: only installed packages are read", sorted(pk) == ["curl", "libc6", "python3-fastapi-login", "unitotem-manager"], sorted(pk))
    check("local packages are recognised", P.is_local("unitotem-manager", pk["unitotem-manager"]) and P.is_local("python3-fastapi-login", pk["python3-fastapi-login"])
          and not P.is_local("curl", pk["curl"]) and not P.is_local("libc6", pk["libc6"]))

    class A: pass
    a = A(); a.src = st; a.arch = "amd64"; a.release = "trixie"; a.out = os.path.join(td, "x.lock"); a.snapshot = "2026-10-27T19:50:56Z"
    P.cmd_freeze(a)
    meta, pinned, local = P.read_lock(a.out)
    check("freeze: archive packages pinned, local ones recorded apart", pinned == {"curl": "8.14.1-2+deb13u7", "libc6": "2.41-12"} and sorted(local) == ["python3-fastapi-login", "unitotem-manager"], (pinned, local))
    check("freeze: arch, release and snapshot are in the header", meta["arch"] == "amd64" and meta["release"] == "trixie" and meta["apt-snapshot"] == "2026-10-27T19:50:56Z")
    check("snapshot timestamp in apt's own format", P.snapshot_ts(meta) == "20261027T195056Z")

    b = A(); b.lock = a.out; b.src = st
    check("verify: identical set passes", P.cmd_verify(b) == 0)
    open(os.path.join(td, "s2"), "w").write(STATUS.replace("2.41-12\nMaintainer: GNU", "2.41-13\nMaintainer: GNU"))
    b.src = os.path.join(td, "s2"); check("verify: a different version fails", P.cmd_verify(b) == 1)
    open(os.path.join(td, "s3"), "w").write(STATUS + "\nPackage: python3-feedparser\nStatus: install ok installed\nArchitecture: all\nVersion: 6.0.11-2\nMaintainer: Debian Python Team <x@debian.org>\n")
    b.src = os.path.join(td, "s3"); check("verify: a new, unlocked package fails (the set changed on purpose or by accident)", P.cmd_verify(b) == 1)
    open(os.path.join(td, "s4"), "w").write(STATUS.split("Package: curl")[0] + "Package: unitotem-manager" + STATUS.split("Package: unitotem-manager")[1])
    b.src = os.path.join(td, "s4"); check("verify: a missing locked package fails", P.cmd_verify(b) == 1)

    import io, contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        c = A(); c.lock = a.out; P.cmd_prefs(c)
    prefs = buf.getvalue()
    check("prefs: every pinned package pinned to its version at priority 1001", "Package: curl\nPin: version 8.14.1-2+deb13u7\nPin-Priority: 1001" in prefs and "unitotem-manager" not in prefs, prefs)

    pol = P.parse_policy(POLICY)
    check("policy parsing: candidates and origins", pol["curl"]["candidate"] == "8.14.1-2+deb13u8" and any("trixie-security" in o for o in pol["curl"]["versions"]["8.14.1-2+deb13u8"]), pol["curl"])
    cand, origs, bpo = P.classify(pol["curl"], "8.14.1-2+deb13u7")
    check("classify: a newer candidate from the security pocket is a security update", cand == "8.14.1-2+deb13u8" and any(P.SECURITY_RE.search(o) for o in origs))
    cand, origs, bpo = P.classify(pol["linux-image-amd64"], "6.12.113-1")
    check("classify: nothing newer in the normal archives, but backports offers 7.2.11 (reported, never an update)", cand is None and bpo == "7.2.11-1~bpo13+1", (cand, bpo))
    cand, origs, bpo = P.classify(pol["libc6"], "2.41-12")
    check("classify: same version = nothing", cand is None and bpo is None)
    cand, origs, bpo = P.classify(pol["curl"], "8.14.1-2+deb13u8")
    check("classify: an older candidate than the locked version is not an update", cand is None)

print("\n%d passed, %d failed" % (ok, fail)); sys.exit(1 if fail else 0)

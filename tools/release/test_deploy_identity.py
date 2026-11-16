#!/usr/bin/env python3
"""Tests of deploy/script/deploy-identity.py (host-side identity merge of a fallback deploy that keeps DATA).
Fixtures only, all under a tmp directory: the old system's /etc upper, the new image's /etc, and the output.

  python3 tools/release/test_deploy_identity.py
"""
import json, os, shutil, stat, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPT = os.path.join(ROOT, "deploy", "script", "deploy-identity.py")
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond:
        ok += 1
        print("PASS:", name)
    else:
        fail += 1
        print("FAIL:", name, extra)


# The old system: the image's accounts plus local ones (admin 1000 in sudo and users, bob 1001, carol 1002 which
# the new image takes over by uid) and a system account the image no longer has (oldsvc 990).
OLD = {
    "passwd": "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
              "systemd-network:x:998:998:systemd Network:/:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n"
              "oldsvc:x:990:990:old:/:/usr/sbin/nologin\n"
              "admin:x:1000:1000:Admin:/home/admin:/bin/bash\nbob:x:1001:1001:Bob:/home/bob:/bin/bash\n"
              "carol:x:1002:1002:Carol:/home/carol:/bin/bash\n",
    "shadow": "root:$6$local$LOCALROOTHASH:19500:0:99999:7:::\ndaemon:*:19000:0:99999:7:::\n"
              "systemd-network:!*:19000::::::\nnobody:*:19000:0:99999:7:::\noldsvc:!*:19000::::::\n"
              "admin:$6$a$ADMINHASH:19600:0:99999:7:::\nbob:$6$b$BOBHASH:19600:0:99999:7:::\n"
              "carol:$6$c$CAROLHASH:19600:0:99999:7:::\n",
    "group": "root:x:0:\ndaemon:x:1:\nsudo:x:27:admin\nusers:x:100:admin,bob\nunitotem:x:995:admin\n"
             "systemd-network:x:998:\noldsvc:x:990:\nadmin:x:1000:\nbob:x:1001:\ncarol:x:1002:\n",
    "gshadow": "root:*::\ndaemon:*::\nsudo:*::admin\nusers:*::admin,bob\nunitotem:!::admin\n"
               "systemd-network:!::\noldsvc:!::\nadmin:!::\nbob:!::\ncarol:!::\n",
}

# The new image: its own system accounts (newsvc 991) and ghost on uid 1002, which takes carol's uid.
NEW = {
    "passwd": "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
              "systemd-network:x:998:998:systemd Network:/:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n"
              "newsvc:x:991:991:new:/:/usr/sbin/nologin\nghost:x:1002:1002:Ghost:/home/ghost:/bin/bash\n",
    "shadow": "root:!:19000:0:99999:7:::\ndaemon:*:19000:0:99999:7:::\nsystemd-network:!*:19000::::::\n"
              "nobody:*:19000:0:99999:7:::\nnewsvc:!*:19000::::::\nghost:!:19000:0:99999:7:::\n",
    "group": "root:x:0:\ndaemon:x:1:\nsudo:x:27:\nusers:x:100:\nshadow:x:42:\nunitotem:x:995:\n"
             "systemd-network:x:998:\nnewsvc:x:991:\nghost:x:1002:\n",
    "gshadow": "root:*::\ndaemon:*::\nsudo:*::\nusers:*::\nshadow:*::\nunitotem:!::\nsystemd-network:!::\n"
               "newsvc:!::\nghost:!::\n",
}


def write_set(d, files):
    os.makedirs(d, exist_ok=True)
    for name, text in files.items():
        with open(os.path.join(d, name), "wb") as f:
            f.write(text if isinstance(text, bytes) else text.encode())


def run(old, new, out):
    p = subprocess.run([sys.executable, "-I", SCRIPT, "--old-dir", old, "--new-dir", new, "--out-dir", out],
                       capture_output=True, text=True, timeout=120)
    try:
        js = json.loads(p.stdout)
    except ValueError:
        js = None
    return p.returncode, js, p.stderr


def rows(path, n):
    with open(path, encoding="utf-8") as f:
        return [l.rstrip("\n").split(":") for l in f if l.strip()]


def by_name(rs):
    return {r[0]: r for r in rs}


TMP = tempfile.mkdtemp(prefix="unitotem-test-deploy-identity.")
try:
    old = os.path.join(TMP, "old")
    new = os.path.join(TMP, "new")
    out = os.path.join(TMP, "out")
    write_set(old, OLD)
    write_set(new, NEW)
    os.makedirs(out)

    rc, js, err = run(old, new, out)
    check("merge exits 0", rc == 0, f"rc={rc} stderr={err}")
    check("output is JSON with ok true", js is not None and js.get("ok") is True, str(js))
    check("shadow gid taken from the merged group file", js is not None and js.get("shadow_gid") == 42, str(js))

    P = by_name(rows(os.path.join(out, "passwd"), 7))
    S = by_name(rows(os.path.join(out, "shadow"), 9))
    G = by_name(rows(os.path.join(out, "group"), 4))
    GS = by_name(rows(os.path.join(out, "gshadow"), 4))

    check("admin (uid 1000) carried with uid and hash",
          "admin" in P and P["admin"][2] == "1000" and "ADMINHASH" in S.get("admin", [""] * 9)[1], str(P.get("admin")))
    check("bob (uid 1001) carried with hash", "bob" in P and "BOBHASH" in S.get("bob", [""] * 9)[1])
    check("root hash comes from the old system", "LOCALROOTHASH" in S["root"][1], str(S.get("root")))
    check("admin is in sudo and users groups", "admin" in G["sudo"][3].split(",") and "admin" in G["users"][3].split(","), str(G.get("sudo")))
    check("admin is in sudo admins (gshadow)", "admin" in GS["sudo"][2].split(",") or "admin" in GS["sudo"][3].split(","), str(GS.get("sudo")))
    check("image system user newsvc kept", "newsvc" in P and P["newsvc"][2] == "991")
    check("image system group shadow kept", "shadow" in G and G["shadow"][2] == "42")
    check("ghost (image, uid 1002) wins the uid clash", "ghost" in P and P["ghost"][2] == "1002")
    check("carol (local, uid 1002) dropped on the uid clash", "carol" not in P and "carol" not in S and "carol" not in G)
    check("stale system account oldsvc is not carried", "oldsvc" not in P and "oldsvc" not in S and "oldsvc" not in G)
    check("every passwd entry has a shadow entry", all(n in S for n in P))

    mode = lambda n: stat.S_IMODE(os.stat(os.path.join(out, n)).st_mode)
    check("passwd mode 644", mode("passwd") == 0o644, oct(mode("passwd")))
    check("shadow mode 640", mode("shadow") == 0o640, oct(mode("shadow")))
    check("gshadow mode 640", mode("gshadow") == 0o640, oct(mode("gshadow")))

    # Deterministic: a second run gives the same bytes.
    out2 = os.path.join(TMP, "out2")
    os.makedirs(out2)
    rc2, _, _ = run(old, new, out2)
    same = rc2 == 0 and all(open(os.path.join(out, n), "rb").read() == open(os.path.join(out2, n), "rb").read()
                            for n in ("passwd", "shadow", "group", "gshadow"))
    check("merge is deterministic", same)

    # Refused: a corrupt old shadow (binary data) -> exit 1, out-dir stays empty.
    old_bad = os.path.join(TMP, "old-bad")
    write_set(old_bad, dict(OLD, shadow=b"root:$6$x:1:0:99999:7:::\n\x00\x01\x02garbage\n"))
    out_bad = os.path.join(TMP, "out-bad")
    os.makedirs(out_bad)
    rc3, js3, err3 = run(old_bad, new, out_bad)
    check("corrupt old shadow is refused with exit 1", rc3 == 1, f"rc={rc3} stderr={err3}")
    check("refusal reports ok false", js3 is not None and js3.get("ok") is False, str(js3))
    check("refusal leaves out-dir empty", os.listdir(out_bad) == [], str(os.listdir(out_bad)))

    # Empty old set: nothing to carry, the image's own files come out unchanged (no local accounts).
    old_empty = os.path.join(TMP, "old-empty")
    os.makedirs(old_empty)
    out_empty = os.path.join(TMP, "out-empty")
    os.makedirs(out_empty)
    rc4, js4, _ = run(old_empty, new, out_empty)
    check("empty old set exits 0", rc4 == 0, f"rc={rc4}")
    if rc4 == 0:
        P4 = by_name(rows(os.path.join(out_empty, "passwd"), 7))
        S4 = by_name(rows(os.path.join(out_empty, "shadow"), 9))
        check("empty old set: no local account", "admin" not in P4 and "bob" not in P4 and "carol" not in P4)
        check("empty old set: root hash is the image's", S4["root"][1] == "!", str(S4.get("root")))

    # Usage errors: a missing directory and a non-empty out-dir -> exit 2, nothing written.
    rc5, _, _ = run(os.path.join(TMP, "nope"), new, os.path.join(TMP, "out5"))
    check("missing old dir is a usage error (exit 2)", rc5 == 2, f"rc={rc5}")
    busy = os.path.join(TMP, "busy")
    os.makedirs(busy)
    with open(os.path.join(busy, "passwd"), "w") as f:
        f.write("keep\n")
    rc6, _, _ = run(old, new, busy)
    check("non-empty out-dir is a usage error (exit 2)", rc6 == 2 and os.listdir(busy) == ["passwd"], f"rc={rc6}")
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

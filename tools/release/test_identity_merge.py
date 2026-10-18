#!/usr/bin/env python3
"""Host-side tests of unitotem/files/unitotem_identity.py (the A/B identity merge). Fixtures only: no target, no qemu.

  python3 tools/release/test_identity_merge.py
"""
import importlib.util, os, shutil, stat, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
spec = importlib.util.spec_from_file_location("unitotem_identity", os.path.join(ROOT, "unitotem/files/unitotem_identity.py"))
ident = importlib.util.module_from_spec(spec); spec.loader.exec_module(ident)
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


BASE = {
    "passwd": "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
              "systemd-network:x:998:998:systemd Network:/:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n",
    "shadow": "root:$6$image$IMAGEHASH:19000:0:99999:7:::\ndaemon:*:19000:0:99999:7:::\nsystemd-network:!*:19000::::::\nnobody:*:19000:0:99999:7:::\n",
    "group": "root:x:0:\ndaemon:x:1:\nshadow:x:42:\nsudo:x:27:\nunitotem:x:995:\nsystemd-network:x:998:\nnogroup:x:65534:\n",
    "gshadow": "root:*::\ndaemon:*::\nshadow:*::\nsudo:*::\nunitotem:!::\nsystemd-network:!::\nnogroup:*::\n",
}
CUR = {
    "passwd": BASE["passwd"] + "alice:x:1000:1000:Alice:/home/alice:/bin/bash\nbob:x:1001:1001:Bob:/home/bob:/bin/bash\n",
    "shadow": "root:$6$local$LOCALROOT:19500:0:99999:7:::\ndaemon:*:19000:0:99999:7:::\nsystemd-network:!*:19000::::::\nnobody:*:19000:0:99999:7:::\n"
              "alice:$6$a$ALICEHASH:19600:0:99999:7:::\nbob:!:19600:0:99999:7:::\n",
    "group": BASE["group"].replace("sudo:x:27:", "sudo:x:27:alice").replace("unitotem:x:995:", "unitotem:x:995:alice,bob,root")
             + "alice:x:1000:\nbob:x:1001:\nstaff2:x:1002:alice,bob\n",
    "gshadow": BASE["gshadow"].replace("sudo:*::", "sudo:*:alice:alice").replace("unitotem:!::", "unitotem:!::alice,bob,root")
               + "alice:!::\nbob:!::\nstaff2:!:alice:alice,bob\n",
}


def rows(text, n):
    return [l.split(":") for l in text.split("\n") if l]


def merge(base=BASE, cur=CUR):
    log = []
    return ident.merge_identity(base, cur, log), log


# 1. the main case ------------------------------------------------------------------------------------------------------------
m, log = merge()
sh = {r[0]: r for r in rows(m["shadow"], 9)}
check("root's hash and aging come from current", sh["root"][1] == "$6$local$LOCALROOT" and sh["root"][2] == "19500")
check("local accounts alice/bob carried with their shadow entries", sh.get("alice", [0, ""])[1] == "$6$a$ALICEHASH" and sh.get("bob", [0, ""])[1] == "!")
check("system accounts come from the image", "systemd-network:x:998:998" in m["passwd"] and sh["daemon"][1] == "*")
g = {r[0]: r for r in rows(m["group"], 4)}
check("unitotem group membership (alice, bob, root) kept", set(g["unitotem"][3].split(",")) == {"alice", "bob", "root"})
check("alice is in sudo", "alice" in g["sudo"][3].split(","))
check("local groups gid>=1000 carried (staff2, alice, bob)", all(x in g for x in ("staff2", "alice", "bob")) and g["staff2"][3] == "alice,bob")
gs = {r[0]: r for r in rows(m["gshadow"], 4)}
check("gshadow members and admins carried", gs["sudo"][2] == "alice" and "alice" in gs["sudo"][3] and gs["staff2"][2] == "alice")
ident.validate(m); check("the result validates", True)
m2, _ = merge(BASE, CUR)
check("idempotent: same inputs, same output", m == m2)
m3, _ = merge(BASE, {k: v for k, v in m.items()})
check("idempotent: merging the output with the same base changes nothing", m == m3)

# 2. edge cases ---------------------------------------------------------------------------------------------------------------
m, _ = merge(BASE, {})
check("empty current files: plain image files", m["passwd"] == BASE["passwd"] and m["shadow"] == BASE["shadow"] and m["group"] == BASE["group"])
m, _ = merge(BASE, {k: v.rstrip("\n") for k, v in CUR.items()})
check("missing trailing newline in current", "alice" in m["passwd"] and m["passwd"].endswith("\n"))
m, _ = merge(BASE, {k: v.replace("\n", "\r\n") for k, v in CUR.items()})
check("CRLF line endings in current", "alice:x:1000" in m["passwd"] and "\r" not in m["passwd"] + m["shadow"] + m["group"] + m["gshadow"])
cur = dict(CUR); cur["shadow"] = CUR["shadow"].replace("alice:$6$a$ALICEHASH", "alice:*").replace("root:$6$local$LOCALROOT", "root:!")
m, _ = merge(BASE, cur)
sh = {r[0]: r for r in rows(m["shadow"], 9)}
check("'*' and '!' hashes are carried as they are (locked root stays locked)", sh["alice"][1] == "*" and sh["root"][1] == "!")
cur = dict(CUR); cur["shadow"] = CUR["shadow"].replace("alice:$6$a$ALICEHASH:19600:0:99999:7:::", "alice:$6$a$ALICEHASH:0:0:1:7:3:1:")
m, _ = merge(BASE, cur)
sh = {r[0]: r for r in rows(m["shadow"], 9)}
check("expired/odd aging fields are carried verbatim", sh["alice"][2:] == ["0", "0", "1", "7", "3", "1", ""])
base2 = dict(BASE); base2["passwd"] = BASE["passwd"] + "newsvc:x:1001:1001:new service:/:/usr/sbin/nologin\n"
base2["shadow"] = BASE["shadow"] + "newsvc:!:19000::::::\n"; base2["group"] = BASE["group"] + "newsvc:x:1001:\n"; base2["gshadow"] = BASE["gshadow"] + "newsvc:!::\n"
log = []
m = ident.merge_identity(base2, CUR, log)
p = {r[0]: r for r in rows(m["passwd"], 7)}
check("uid clash with a NEW image account: the image wins, the local one is dropped and logged", p["newsvc"][2] == "1001" and "bob" not in p and any("bob" in l and "clash" in l for l in log), str(log))
ident.validate(m)
base3 = dict(BASE); base3["passwd"] = BASE["passwd"] + "alice:x:999:999:image alice:/:/usr/sbin/nologin\n"
base3["shadow"] = BASE["shadow"] + "alice:!:19000::::::\n"; base3["group"] = BASE["group"] + "alice:x:999:\n"; base3["gshadow"] = BASE["gshadow"] + "alice:!::\n"
m = ident.merge_identity(base3, CUR, [])
p = {r[0]: r for r in rows(m["passwd"], 7)}
check("name clash: the image's account wins", p["alice"][2] == "999")
base4 = dict(BASE); base4["group"] = BASE["group"] + "newgrp:x:1002:\n"; base4["gshadow"] = BASE["gshadow"] + "newgrp:!::\n"
m = ident.merge_identity(base4, CUR, [])
g = {r[0]: r for r in rows(m["group"], 4)}
check("gid clash: the image's group wins, the local group with that gid is dropped", "newgrp" in g and "staff2" not in g)
ident.validate(m)
cur = dict(CUR); cur["group"] = CUR["group"].replace("sudo:x:27:alice", "sudo:x:27:alice,ghost"); cur["passwd"] = CUR["passwd"]
m, _ = merge(BASE, cur)
g = {r[0]: r for r in rows(m["group"], 4)}
check("a member that does not exist is dropped", "ghost" not in g["sudo"][3])
cur = dict(CUR); cur["group"] = "root:x:0:\nunitotem:x:995:alice\n"   # image groups sudo/shadow missing in current; alice's own group gone
m, _ = merge(BASE, cur)
p = {r[0]: r for r in rows(m["passwd"], 7)}
check("an account whose group no longer exists is still carried (the image decides the groups)", "alice" in p)
ident.validate(m)
cur = dict(CUR); cur["shadow"] = CUR["shadow"].replace("root:$6$local$LOCALROOT:19500:0:99999:7:::\n", "")
m, _ = merge(BASE, cur)
sh = {r[0]: r for r in rows(m["shadow"], 9)}
check("root missing in current shadow: the image's root entry is kept", sh["root"][1] == "$6$image$IMAGEHASH")
cur = dict(CUR); cur["passwd"] = CUR["passwd"].replace("root:x:0:0:root:/root:/bin/bash\n", "")
m, _ = merge(BASE, cur)
check("root missing in current passwd: root comes from the image", m["passwd"].startswith("root:x:0:0:"))
cur = dict(CUR); cur["shadow"] = CUR["shadow"] + "ghostuser:$6$x$y:19000:0:99999:7:::\n"
m, _ = merge(BASE, cur)
check("a shadow entry without a passwd entry is dropped", "ghostuser" not in m["shadow"])
cur = dict(CUR); cur["shadow"] = CUR["shadow"].replace("bob:!:19600:0:99999:7:::\n", "")
m, log = merge(BASE, cur)
sh = {r[0]: r for r in rows(m["shadow"], 9)}
check("an account without a shadow entry is carried locked", sh["bob"][1] == "!" and any("bob" in l for l in log))
cur = dict(CUR); cur["passwd"] = "\n\nnot a passwd line\n::::::\n" + CUR["passwd"] + "dup:x:1:2\n"
m, log = merge(BASE, cur)
check("blank/malformed lines are skipped, not fatal", "alice" in m["passwd"] and any("skipped" in l for l in log))
try:
    ident.merge_identity(BASE, {"passwd": "x" * (5 * 1024 * 1024), "shadow": "", "group": "", "gshadow": ""}, [])
    check("a huge file is refused", False)
except ident.MergeError:
    check("a huge file is refused", True)
try:
    ident.merge_identity(BASE, {"passwd": b"\x00\x01\xff\xfe" * 100, "shadow": "", "group": "", "gshadow": ""}, [])
    check("binary garbage is refused", False)
except ident.MergeError:
    check("binary garbage is refused", True)
try:
    ident.merge_identity({"passwd": "daemon:x:1:1:::\n", "shadow": "", "group": "", "gshadow": ""}, CUR, [])
    check("an image without root is refused", False)
except ident.MergeError:
    check("an image without root is refused", True)
cur = dict(CUR); cur["passwd"] = CUR["passwd"] + "sneaky:x:0:0:uid0:/root:/bin/bash\n"
m, _ = merge(BASE, cur)
check("a local uid-0 account other than root is not carried (uid < 1000)", "sneaky" not in m["passwd"])
cur = dict(CUR); cur["passwd"] = CUR["passwd"] + "big:x:65534:65534::/:/bin/false\nhuge:x:70000:70000::/:/bin/false\n"
m, _ = merge(BASE, cur)
pp = {r[0] for r in rows(m["passwd"], 7)}
check("uids >= 65534 are not carried (nobody stays the image's)", "huge" not in pp and "big" not in pp and "nobody" in pp)

# pwck/grpck (when installed) accept the merged files and flag a genuinely broken set
import shutil as _sh
if _sh.which("pwck") or os.path.exists("/usr/sbin/pwck"):
    m, _ = merge()
    try:
        ident.tool_check(BASE, m); check("pwck/grpck -r accept the merged files", True)
    except ident.MergeError as e:
        check("pwck/grpck -r accept the merged files", False, str(e))
    broken = dict(m); broken["passwd"] = m["passwd"] + "dup2:x:1000:1000::/:/bin/false\nalice:x:1005:1005:dup:/:/bin/false\n"
    try:
        ident.tool_check(BASE, broken); check("pwck flags a duplicated name", False)
    except ident.MergeError:
        check("pwck flags a duplicated name", True)
else:
    print("SKIP: pwck not installed on this host")

# 3. validate() rejects bad results ------------------------------------------------------------------------------------------
bad = dict(BASE); bad["shadow"] = BASE["shadow"] + "orphan:!:19000::::::\n"
try: ident.validate(bad); check("validate: shadow entry without passwd entry", False)
except ident.MergeError: check("validate: shadow entry without passwd entry", True)
bad = dict(BASE); bad["group"] = BASE["group"].replace("sudo:x:27:", "sudo:x:27:nobody-here")
try: ident.validate(bad); check("validate: nonexistent group member", False)
except ident.MergeError: check("validate: nonexistent group member", True)
bad = dict(BASE); bad["passwd"] = BASE["passwd"] + "dupuid:x:1:1:::\n"
try: ident.validate(bad); check("validate: duplicate uid", False)
except ident.MergeError: check("validate: duplicate uid", True)

# 4. files: install, pre-update, never touch the old slot, fallback ----------------------------------------------------------
with tempfile.TemporaryDirectory() as t:
    base_d, cur_d, dst = (os.path.join(t, x) for x in ("base", "cur", "newupper"))
    for d, s in ((base_d, BASE), (cur_d, CUR)):
        os.makedirs(d)
        for n, v in s.items(): open(os.path.join(d, n), "w").write(v)
    before = {n: open(os.path.join(cur_d, n)).read() for n in ident.FILES}
    r = ident.apply_merge(base_d, cur_d, dst)
    check("apply_merge ok on real files", r["ok"], str(r))
    check("the old slot's files are untouched", before == {n: open(os.path.join(cur_d, n)).read() for n in ident.FILES})
    st = {n: stat.S_IMODE(os.stat(os.path.join(dst, n)).st_mode) for n in ident.FILES}
    check("modes: passwd/group 0644, shadow/gshadow 0640", st == {"passwd": 0o644, "group": 0o644, "shadow": 0o640, "gshadow": 0o640}, str(st))
    check("no temp files left behind", not [f for f in os.listdir(dst) if f.endswith(".unitotem-new")])
    r = ident.apply_merge(base_d, cur_d, dst)
    check("re-runnable: second run ok and keeps *.pre-update", r["ok"] and all(os.path.exists(os.path.join(dst, n + ".pre-update")) for n in ident.FILES))
    a = open(os.path.join(dst, "shadow")).read()
    open(os.path.join(cur_d, "passwd"), "wb").write(b"\x00\xff" * 50)          # now the current files are garbage
    r = ident.apply_merge(base_d, cur_d, dst)
    check("garbage in current: fallback to the image files (nothing in the upper), reported, never raises",
          (not r["ok"]) and "FAILED" in r["detail"] and not any(os.path.exists(os.path.join(dst, n)) for n in ident.FILES), str(r))
    shutil.rmtree(base_d)
    r = ident.apply_merge(base_d, cur_d, dst)
    check("missing base dir: fallback, never raises", not r["ok"])

# 5. through the update engine: prepare_overlays (fetch) and a re-merge at apply --------------------------------------------------
import importlib.machinery
loader = importlib.machinery.SourceFileLoader("uu", os.path.join(ROOT, "unitotem/files/unitotem-update"))
uspec = importlib.util.spec_from_loader("uu", loader); uu = importlib.util.module_from_spec(uspec); loader.exec_module(uu)
sys.modules["unitotem_identity"] = ident
with tempfile.TemporaryDirectory() as t:
    data, newroot, curetc, state = (os.path.join(t, x) for x in ("data", "newroot", "curetc", "state"))
    os.makedirs(os.path.join(newroot, "etc/unitotem")); os.makedirs(curetc); os.makedirs(os.path.join(data, "upper/etc.a"))
    open(os.path.join(newroot, "etc/unitotem/ota-preserve.list"), "w").write("hostname\n")
    for n in ident.FILES:
        open(os.path.join(newroot, "etc", n), "w").write(BASE[n]); open(os.path.join(curetc, n), "w").write(CUR[n])
    conf = dict(uu.CONF_DEFAULTS, UPDATE_DATA=data, UPDATE_STATE_DIR=state, UPDATE_ETC_CURRENT=curetc)
    uu.prepare_overlays(conf, "b", "a", newroot)
    up = os.path.join(data, "upper/etc.b")
    check("fetch: the new slot's upper gets the merged files", "alice:x:1000" in open(os.path.join(up, "passwd")).read()
          and "$6$local$LOCALROOT" in open(os.path.join(up, "shadow")).read())
    check("fetch: the old slot's upper is untouched", os.listdir(os.path.join(data, "upper/etc.a")) == [])
    st = uu.read_state(conf, "identity-merge.json")
    check("fetch: the result is in the update state (shown in status)", st and st["ok"] and st["slot"] == "b", str(st))
    # a password changed after the download: apply merges again from the saved image files
    open(os.path.join(curetc, "shadow"), "w").write(CUR["shadow"].replace("$6$local$LOCALROOT", "$6$newer$CHANGEDLATER"))
    shutil.rmtree(newroot)                                   # the new slot is not mounted at apply
    uu.merge_identity_into(conf, "b")
    check("apply: re-merged from the saved base, the later change is not lost", "$6$newer$CHANGEDLATER" in open(os.path.join(up, "shadow")).read())
    open(os.path.join(curetc, "passwd"), "wb").write(b"\x00\xff" * 64)
    uu.merge_identity_into(conf, "b")
    st = uu.read_state(conf, "identity-merge.json")
    check("a broken current file does not fail the update: image files, failure reported", st and not st["ok"] and "FAILED" in st["detail"]
          and not os.path.exists(os.path.join(up, "passwd")), str(st))
    ident_mod = sys.modules.pop("unitotem_identity")
    sys.path_backup = list(sys.path); sys.path[:] = [p for p in sys.path if p != "/usr/lib/unitotem"]
    uu.merge_identity_into(conf, "b")
    st = uu.read_state(conf, "identity-merge.json")
    check("module missing: reported, never raises", st and not st["ok"] and "not run" in st["detail"], str(st))
    sys.path[:] = sys.path_backup; sys.modules["unitotem_identity"] = ident_mod

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)

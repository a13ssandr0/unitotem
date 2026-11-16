#!/usr/bin/env python3
"""Host-side identity merge for the fallback deploy with data kept (called by identity-carry.sh).

The recovery initrd has no Python, so the merge of the local accounts (unitotem/files/unitotem_identity.py, apply_merge)
runs here, on the deploy host:
    base    = the new image's /etc/{passwd,group,shadow,gshadow}   (--new-dir)
    current = the old system's /etc upper, archived in DATA history (--old-dir)
The result is written to --out-dir only when the merge succeeds; a refused merge leaves --out-dir empty.

  python3 -I deploy/script/deploy-identity.py --old-dir D --new-dir D --out-dir D

stdout: one JSON object {"ok", "detail", "log", "shadow_gid"}. Exit 0 merged, 1 refused, 2 usage error.
"""
import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CANDIDATES = (
    os.path.join(HERE, "..", "..", "unitotem", "files", "unitotem_identity.py"),   # repository layout
    os.path.join(HERE, "unitotem_identity.py"),                                    # copy beside this script
)


def load_identity():
    for path in CANDIDATES:
        path = os.path.normpath(path)
        if os.path.isfile(path):
            spec = importlib.util.spec_from_file_location("unitotem_identity", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise SystemExit("unitotem_identity.py not found next to this script or in unitotem/files/")


def shadow_gid(out_dir):
    """gid of the group 'shadow' in the merged group file, or None."""
    try:
        with open(os.path.join(out_dir, "group"), encoding="utf-8") as f:
            for line in f:
                fields = line.rstrip("\n").split(":")
                if len(fields) == 4 and fields[0] == "shadow" and fields[2].isdigit():
                    return int(fields[2])
    except OSError:
        pass
    return None


def main(argv):
    ap = argparse.ArgumentParser(description="Merge the local accounts into the new image's identity files.")
    ap.add_argument("--old-dir", required=True, help="old system's /etc files (current)")
    ap.add_argument("--new-dir", required=True, help="new image's /etc files (base)")
    ap.add_argument("--out-dir", required=True, help="empty directory for the merged files")
    args = ap.parse_args(argv)

    for d in (args.old_dir, args.new_dir):
        if not os.path.isdir(d):
            print(json.dumps({"ok": False, "detail": f"not a directory: {d}", "log": [], "shadow_gid": None}))
            return 2
    os.makedirs(args.out_dir, exist_ok=True)
    if os.listdir(args.out_dir):
        print(json.dumps({"ok": False, "detail": "out-dir is not empty", "log": [], "shadow_gid": None}))
        return 2

    ident = load_identity()
    res = ident.apply_merge(base_dir=args.new_dir, current_dir=args.old_dir, dest_dir=args.out_dir)
    gid = shadow_gid(args.out_dir) if res["ok"] else None
    if not res["ok"]:
        # apply_merge removes what it may have written; make sure nothing is left behind
        for name in ident.FILES:
            for suffix in ("", ".pre-update", ".unitotem-new"):
                try:
                    os.unlink(os.path.join(args.out_dir, name + suffix))
                except OSError:
                    pass
    for line in res["log"]:
        print(f"identity: {line}", file=sys.stderr)
    print(f"identity: {res['detail']}", file=sys.stderr)
    print(json.dumps({"ok": res["ok"], "detail": res["detail"], "log": res["log"], "shadow_gid": gid}))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

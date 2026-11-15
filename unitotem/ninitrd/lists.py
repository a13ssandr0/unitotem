"""Reader of unitotem/files/ota-initrd.list, the name list shared by ota-hook and the native initrd builder."""

import re
import sys
from pathlib import Path

DIRECTIVES = frozenset({
    "bin", "real", "file", "logo", "terminfo", "module", "module-opt",
    "x86-bin", "x86-module", "x86-dir",
})
NAME_RE = re.compile(r"[A-Za-z0-9._+/-]+")
TERMINFO_RE = re.compile(r"[a-z0-9]/[A-Za-z0-9._+-]+")
LOGO_RE = re.compile(r"[A-Za-z0-9._+-]+")
PATH_DIRECTIVES = frozenset({"file", "x86-dir"})


class ListError(ValueError):
    """A malformed line; the message carries file and line number."""


def _check_args(where, directive, args):
    if not args:
        raise ListError(f"{where}: '{directive}' needs at least one argument")
    if directive == "file" and len(args) > 2:
        raise ListError(f"{where}: 'file' takes SRC [DST]")
    for arg in args:
        if not NAME_RE.fullmatch(arg) or ".." in arg.split("/"):
            raise ListError(f"{where}: invalid name {arg!r}")
        if directive in PATH_DIRECTIVES and not arg.startswith("/"):
            raise ListError(f"{where}: '{directive}' needs absolute paths, got {arg!r}")
        elif directive == "terminfo" and not TERMINFO_RE.fullmatch(arg):
            raise ListError(f"{where}: terminfo entry must be L/NAME, got {arg!r}")
        elif directive == "logo" and not LOGO_RE.fullmatch(arg):
            raise ListError(f"{where}: logo name must not contain '/', got {arg!r}")


def read_list(path):
    """Return [(directive, [args]), ...] in file order. Raises ListError on any malformed line."""
    entries = []
    text = Path(path).read_text(encoding="utf-8")
    for lineno, line in enumerate(text.splitlines(), 1):
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        directive, args = fields[0], fields[1:]
        where = f"{path}:{lineno}"
        if directive not in DIRECTIVES:
            raise ListError(f"{where}: unknown directive {directive!r}")
        _check_args(where, directive, args)
        entries.append((directive, args))
    return entries


def main(argv):
    if len(argv) != 2:
        print("usage: lists.py FILE", file=sys.stderr)
        return 2
    try:
        entries = read_list(argv[1])
    except (OSError, UnicodeDecodeError, ListError) as exc:
        print(f"lists.py: {exc}", file=sys.stderr)
        return 1
    for directive, args in entries:
        print(" ".join([directive, *args]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

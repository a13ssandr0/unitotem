"""Product version scheme, shared by unitotem-release, fake-github.py and the tests.

  2026.12          monthly release
  2026.12.1        same-month fix (2026.12.1 > 2026.12)
  2026.12~rc1      pre-release (sorts before 2026.12; ~dev1 and ~rc1 are both pre-releases)

The version string is the dpkg form: it is what manifest.json and release-version carry. A git tag cannot
contain "~", so the tag is "v" + version with "~" replaced by "-" (v2026.12-rc1). Nothing else is mapped.
"""
import functools
import re

VERSION_RE = re.compile(r"[0-9]{4}\.[0-9]{2}(\.[0-9]+)?(~[a-z]+[0-9]+)?")
TAG_RE = re.compile(r"v[0-9]{4}\.[0-9]{2}(\.[0-9]+)?(-[a-z]+[0-9]+)?")


class VersionError(ValueError):
    pass


def validate(v):
    """Return v if it is a version of the scheme, else raise VersionError."""
    if not isinstance(v, str) or not VERSION_RE.fullmatch(v):
        raise VersionError(f"invalid version {v!r}: expected YYYY.MM, YYYY.MM.N or YYYY.MM~tagN (e.g. 2026.12, 2026.12.1, 2026.12~rc1)")
    return v


def tag_from_version(v):
    """Git tag of a version: 'v' + version, with '~' replaced by '-'."""
    validate(v)
    return "v" + v.replace("~", "-")


def version_from_tag(tag):
    """Version of a git tag (inverse of tag_from_version); raises VersionError for anything else."""
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise VersionError(f"invalid tag {tag!r}: expected vYYYY.MM, vYYYY.MM.N or vYYYY.MM-tagN (e.g. v2026.12-rc1)")
    return tag[1:].replace("-", "~")


def _isdigit(c):
    return "0" <= c <= "9"


def _order(c):
    """dpkg's order of one non-digit character: '~' before the end of the string, end, letters, the rest."""
    if c == "" or _isdigit(c):
        return 0
    if c == "~":
        return -1
    if c.isascii() and c.isalpha():
        return ord(c)
    return ord(c) + 256


def _verrevcmp(a, b):
    # Inspired by dpkg's verrevcmp (lib/dpkg/version.c): alternate non-digit and digit runs.
    i = j = 0
    while i < len(a) or j < len(b):
        first_diff = 0
        while (i < len(a) and not _isdigit(a[i])) or (j < len(b) and not _isdigit(b[j])):
            ac = _order(a[i] if i < len(a) else "")
            bc = _order(b[j] if j < len(b) else "")
            if ac != bc:
                return ac - bc
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        while i < len(a) and _isdigit(a[i]) and j < len(b) and _isdigit(b[j]):
            if not first_diff:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and _isdigit(a[i]):
            return 1
        if j < len(b) and _isdigit(b[j]):
            return -1
        if first_diff:
            return first_diff
    return 0


def compare(a, b):
    """dpkg --compare-versions order of two versions: negative, zero or positive."""
    return _verrevcmp(a, b)


key = functools.cmp_to_key(compare)
"""Sort key of versions in dpkg order: sorted(versions, key=key)."""

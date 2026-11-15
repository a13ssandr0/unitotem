"""Staging of target files into the initrd tree (no code is run from ROOT).

Port of initramfs-tools 0.151 hook-functions: copy_file and copy_exec.
Every path given to the API is absolute inside the target. Reads come from ROOT, writes go to DEST.
Symlinks in ROOT are resolved against ROOT, never against the host filesystem.
Library dependencies are read with readelf (ELF headers only), never with ldd.
"""

import errno
import fnmatch
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

SEARCH_PATH = "/usr/bin:/sbin:/bin"  # PATH exported by mkinitramfs
TRIPLETS = {"arm64": "aarch64-linux-gnu", "amd64": "x86_64-linux-gnu"}
# Default library directories of the target ld.so (ld.so.conf of Debian).
LIBDIRS = ("/lib/{triplet}", "/usr/lib/{triplet}", "/lib", "/usr/lib")
MAX_LINKS = 40
# readelf prints localized labels; the parser needs the English ones.
READELF_ENV = dict(os.environ, LC_ALL="C", LANG="C")

RE_NEEDED = re.compile(r"\(NEEDED\)\s+Shared library: \[(.+)\]")
RE_RUNPATH = re.compile(r"\(RUNPATH\)\s+Library runpath: \[(.*)\]")
RE_RPATH = re.compile(r"\(RPATH\)\s+Library rpath: \[(.*)\]")
RE_INTERP = re.compile(r"Requesting program interpreter: (.+)\]")


def _stderr(message):
    print(message, file=sys.stderr)


def _usrmerged(path):
    # Same pattern as the case statements of copy_file: /bin/* /lib* /sbin/*
    return path.startswith(("/bin/", "/lib", "/sbin/"))


@dataclass
class _ElfInfo:
    needed: list = field(default_factory=list)
    runpath: list | None = None
    rpath: list | None = None
    interp: str | None = None


class Stage:
    """Fills DEST with files of the target tree ROOT (initramfs-tools hook-functions semantics)."""

    def __init__(self, root, dest, arch, kver, warn=_stderr):
        if arch not in TRIPLETS:
            raise ValueError(f"unsupported arch: {arch}")
        self.root = Path(root)
        self.dest = Path(dest)
        self.arch = arch
        self.kver = kver
        self.warn = warn
        self._root_s = str(self.root).rstrip("/")
        self._dest_s = str(self.dest).rstrip("/")
        self._elf_cache = {}
        self._warned = set()

    @property
    def triplet(self):
        return TRIPLETS[self.arch]

    def _host(self, path):
        """Host location of an absolute target path in ROOT (path must be resolved)."""
        return self._root_s + "/" + path.lstrip("/")

    def _dst(self, path):
        """Host location of a target path in DEST (lexical, as the stock hook)."""
        return self._dest_s + "/" + path.lstrip("/")

    def readlink_f(self, path):
        """readlink -f inside ROOT: every symlink is followed, absolute targets are re-rooted at ROOT.

        Missing components are accepted, as with GNU readlink -f. Raises OSError(ELOOP) on link loops.
        """
        pending = deque(path.split("/"))
        resolved = []
        links = 0
        while pending:
            comp = pending.popleft()
            if comp in ("", "."):
                continue
            if comp == "..":
                if resolved:
                    resolved.pop()
                continue
            host = self._host("/".join(resolved + [comp]))
            if os.path.islink(host):
                links += 1
                if links > MAX_LINKS:
                    raise OSError(errno.ELOOP, "too many symbolic links", path)
                target = os.readlink(host)
                if target.startswith("/"):
                    resolved = []
                pending.extendleft(reversed(target.split("/")))
                continue
            resolved.append(comp)
        return "/" + "/".join(resolved)

    def _root_isfile(self, path):
        try:
            return os.path.isfile(self._host(self.readlink_f(path)))
        except OSError:
            return False

    def _root_isexec(self, path):
        try:
            host = self._host(self.readlink_f(path))
            st = os.stat(host)
        except OSError:
            return False
        return stat.S_ISREG(st.st_mode) and (st.st_mode & 0o111) != 0

    def command_v(self, name):
        """command -v against the target PATH. Returns the path as found, symlinks not resolved."""
        if "/" in name:
            return name if self._root_isexec(name) else None
        for directory in SEARCH_PATH.split(":"):
            candidate = directory + "/" + name
            if self._root_isexec(candidate):
                return candidate
        return None

    def copy_file(self, kind, src, target=None):
        """Port of hook-functions copy_file.

        Returns 0 copied (or symlink created and target copied), 1 target already present,
        2 source missing or copy error.
        """
        target = target or src
        if not self._root_isfile(src):
            return 2

        raw = target
        if os.path.isdir(self._dst(raw)) or raw.endswith("/"):
            raw = raw + "/" + posixpath.basename(src)
        # realpath -ms, lexical only: DEST is never resolved through the host
        target = posixpath.normpath("/" + raw.lstrip("/"))

        # usr-merge canonicalisation of source and target
        if self.readlink_f("/bin") == "/usr/bin" and src.startswith(("/bin/", "/lib", "/sbin/")):
            src = "/usr" + src
        if _usrmerged(target):
            target = "/usr" + target

        if os.path.exists(self._dst(target)):
            return 1
        os.makedirs(posixpath.dirname(self._dst(target)), exist_ok=True)

        try:
            link_target = self.readlink_f(src)
        except OSError:
            return 2
        # realpath -s: lexical, a symlink component in src makes the path differ
        if link_target != posixpath.normpath("/" + src.lstrip("/")):
            src = link_target
            if _usrmerged(link_target):
                link_target = "/usr" + link_target
            if link_target != target:
                self._relative_link(link_target, target)
            target = link_target
            if os.path.exists(self._dst(target)):
                return 0
            os.makedirs(posixpath.dirname(self._dst(target)), exist_ok=True)

        try:
            shutil.copy2(self._host(src), self._dst(target), follow_symlinks=False)
        except OSError:
            return 2
        return 0

    def _relative_link(self, link_target, target):
        """ln -rs DEST/link_target DEST/target. A failure is reported and does not stop the copy."""
        link = self._dst(target)
        if os.path.lexists(link):
            self.warn(f"W: cannot link {target}: already exists as a dangling entry")
            return
        os.symlink(os.path.relpath(self._dst(link_target), posixpath.dirname(link)), link)

    def copy_exec(self, src, target=None):
        """Port of hook-functions copy_exec: the binary and its library closure.

        The library closure comes from readelf (see libraries()), not from ldd.
        Returns 0 on success or when the binary is already present, >0 on error.
        """
        target = target or src
        rc = self.copy_file("binary", src, target)
        if rc:
            # Stock behaviour: an existing binary ends the call, its libraries are assumed present.
            return rc - 1
        for lib in self.libraries(src):
            if fnmatch.fnmatchcase(lib, "*/libpthread.so.*"):
                rc = self.copy_libgcc()
                if rc:
                    return rc
            rc = self.copy_file("binary", lib)
            if rc not in (0, 1):
                return rc - 1
        return 0

    def copy_libgcc(self):
        """Port of hook-functions copy_libgcc: libgcc_s.so.[1-9] from the target system dirs."""
        for directory in LIBDIRS:
            directory = directory.format(triplet=self.triplet)
            try:
                names = sorted(os.listdir(self._host(self.readlink_f(directory))))
            except OSError:
                continue
            for name in names:
                if not fnmatch.fnmatchcase(name, "libgcc_s.so.[1-9]"):
                    continue
                library = directory + "/" + name
                if not self._root_isfile(library):
                    continue
                rc = self.copy_exec(library)
                if rc:
                    return rc
        return 0

    def libraries(self, src):
        """Shared libraries and interpreter that ldd would list for src, in discovery order.

        Search order of the target ld.so: DT_RUNPATH of the requesting object, else its DT_RPATH,
        then LIBDIRS. LD_LIBRARY_PATH is ignored. $ORIGIN is the directory of the requesting object.
        Ancestor RPATH is not searched (the stage-1 binaries checked carry no RPATH or RUNPATH).
        A NEEDED entry that is not found is reported once and skipped.
        """
        found = []
        seen = {self.readlink_f(src)}
        queue = deque([self.readlink_f(src)])
        while queue:
            obj = queue.popleft()
            info = self._elf_info(obj)
            if info is None:
                continue
            origin = posixpath.dirname(obj)
            candidates = []
            if info.interp:
                candidates.append(info.interp)
            for name in info.needed:
                path = self._find_lib(name, origin, info)
                if path is None:
                    if name not in self._warned:
                        self._warned.add(name)
                        self.warn(f"W: {name} (needed by {obj}) not found in {self.root}, skipped")
                    continue
                candidates.append(path)
            for path in candidates:
                key = self.readlink_f(path)
                if key in seen:
                    continue
                seen.add(key)
                found.append(path)
                queue.append(key)
        return found

    def _find_lib(self, name, origin, info):
        if "/" in name:
            return name if self._root_isfile(name) else None
        dirs = info.runpath if info.runpath is not None else (info.rpath or [])
        dirs = list(dirs) + [d.format(triplet=self.triplet) for d in LIBDIRS]
        for directory in dirs:
            directory = directory.replace("${ORIGIN}", origin).replace("$ORIGIN", origin)
            if not directory.startswith("/"):
                continue
            candidate = directory.rstrip("/") + "/" + name
            if self._root_isfile(candidate):
                return candidate
        return None

    def _elf_info(self, real):
        """readelf -d/-l of a resolved ELF file in ROOT. None for non-ELF files (scripts)."""
        if real in self._elf_cache:
            return self._elf_cache[real]
        host = self._host(real)
        info = None
        try:
            with open(host, "rb") as fh:
                is_elf = fh.read(4) == b"\x7fELF"
        except OSError:
            is_elf = False
        if is_elf:
            out = subprocess.run(
                ["readelf", "-W", "-d", "-l", host],
                env=READELF_ENV, capture_output=True, text=True, check=False,
            )
            if out.returncode != 0:
                raise RuntimeError(f"readelf failed on {real}: {out.stderr.strip()}")
            info = _ElfInfo()
            for line in out.stdout.splitlines():
                if (m := RE_NEEDED.search(line)):
                    info.needed.append(m.group(1))
                elif (m := RE_RUNPATH.search(line)):
                    info.runpath = [d for d in m.group(1).split(":") if d]
                elif (m := RE_RPATH.search(line)):
                    info.rpath = [d for d in m.group(1).split(":") if d]
                elif (m := RE_INTERP.search(line)):
                    info.interp = m.group(1)
        self._elf_cache[real] = info
        return info

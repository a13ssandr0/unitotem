#!/usr/bin/env python3
"""Type into the lab VM through libvirt (virsh send-key), for the guest's ITALIAN keyboard layout.
   winkeys.py DOMAIN text "powershell -ep bypass"     type characters (letters, digits, space - _ . , : ; \\ | / " ' = ( ) $)
   winkeys.py DOMAIN ustext "ls (hd0,gpt1)/"          same, US layout (GRUB, OVMF menus)
   winkeys.py DOMAIN key KEY_ENTER [KEY_X ...]        press keys together (Linux key names)
   winkeys.py DOMAIN shot out.png                     screenshot (scaled to 960 wide)"""
import subprocess, sys, time
SH = "KEY_LEFTSHIFT"
MAP = {" ": ["KEY_SPACE"], "-": ["KEY_SLASH"], "_": [SH, "KEY_SLASH"], ".": ["KEY_DOT"], ",": ["KEY_COMMA"],
       ":": [SH, "KEY_DOT"], ";": [SH, "KEY_COMMA"], "\\": ["KEY_GRAVE"], "|": [SH, "KEY_GRAVE"], "/": [SH, "KEY_7"],
       '"': [SH, "KEY_2"], "'": ["KEY_MINUS"], "=": [SH, "KEY_0"], "(": [SH, "KEY_8"], ")": [SH, "KEY_9"], "$": [SH, "KEY_4"]}
US = {" ": ["KEY_SPACE"], "-": ["KEY_MINUS"], "_": [SH, "KEY_MINUS"], ".": ["KEY_DOT"], ",": ["KEY_COMMA"], "/": ["KEY_SLASH"],
      "=": ["KEY_EQUAL"], "+": [SH, "KEY_EQUAL"], "(": [SH, "KEY_9"], ")": [SH, "KEY_0"], "$": [SH, "KEY_4"], ":": [SH, "KEY_SEMICOLON"], ";": ["KEY_SEMICOLON"],
      "\\": ["KEY_BACKSLASH"], "'": ["KEY_APOSTROPHE"], '"': [SH, "KEY_APOSTROPHE"], "|": [SH, "KEY_BACKSLASH"], "*": [SH, "KEY_8"], "?": [SH, "KEY_SLASH"]}
def virsh(*a): return subprocess.run(["virsh", "-c", "qemu:///system", *a], capture_output=True, text=True)
def keys(dom, ks): virsh("send-key", dom, "--holdtime", "40", *ks); time.sleep(0.06)
def typ(dom, s):
    for ch in s:
        if ch.isalpha() and ch.isascii(): ks = ([SH] if ch.isupper() else []) + ["KEY_" + ch.upper()]
        elif ch.isdigit(): ks = ["KEY_" + ch]
        elif ch in MAP: ks = MAP[ch]
        else: sys.exit("no mapping for %r" % ch)
        keys(dom, ks)
def ustyp(dom, s):
    """for firmware/GRUB consoles, which use the US layout (the Italian map above is for Windows)"""
    for ch in s:
        if ch.isalpha() and ch.isascii(): ks = ([SH] if ch.isupper() else []) + ["KEY_" + ch.upper()]
        elif ch.isdigit(): ks = ["KEY_" + ch]
        elif ch in US: ks = US[ch]
        else: sys.exit("no mapping for %r" % ch)
        keys(dom, ks)
def shot(dom, out):
    import tempfile, os
    fd, ppm = tempfile.mkstemp(suffix=".ppm"); os.close(fd)
    try:
        virsh("screenshot", dom, ppm)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", ppm, "-vf", "scale=960:-1", out], check=True)
    finally:
        os.unlink(ppm)
if __name__ == "__main__":
    dom, cmd, *rest = sys.argv[1:]
    if cmd == "text": typ(dom, " ".join(rest))
    elif cmd == "ustext": ustyp(dom, " ".join(rest))
    elif cmd == "key": keys(dom, rest)
    elif cmd == "shot": shot(dom, rest[0])

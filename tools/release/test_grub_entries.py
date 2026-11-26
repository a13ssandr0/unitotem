#!/usr/bin/env python3
"""Test of unitotem/files/grub-ab-entries: the GRUB text it prints, checked without any device.

  python3 tools/release/test_grub_entries.py

The script is run with sh (it only prints the configuration); grub-script-check parses the result when installed.
"""
import os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ENTRIES = os.path.join(ROOT, "unitotem/files/grub-ab-entries")
DEFAULTS = os.path.join(ROOT, "unitotem/files/grub-default")
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def has_word(word, text):
    return re.search(r"(?<![\w.=-])%s(?![\w.=-])" % re.escape(word), text) is not None


def menu_ids(lines):
    """(number, id, index of the menuentry line) for every line starting with menuentry."""
    out = []
    for i, line in enumerate(lines):
        if re.match(r"^menuentry\b", line):
            m = re.search(r"--id\s+(\S+)", line)
            out.append((len(out), m.group(1) if m else None, i))
    return out


def block(lines, start):
    """Lines of the menuentry starting at index start, up to its closing brace."""
    for j in range(start + 1, len(lines)):
        if lines[j].strip() == "}":
            return lines[start:j + 1]
    return lines[start:]


def entry(lines, name):
    for num, eid, idx in menu_ids(lines):
        if eid == name:
            return block(lines, idx)
    return []


def kernel(blk):
    for line in blk:
        if line.strip().startswith("linux "):
            return line
    return ""


def function_body(lines, name):
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^function %s\s*\{" % re.escape(name), line):
            start = i
            break
    if start is None:
        return None, None
    for j in range(start + 1, len(lines)):
        if lines[j].strip() == "}":
            return start, lines[start + 1:j]
    return start, lines[start + 1:]


def check_slot(lines, slot):
    """Errors of the slot-a / slot-b entry, empty when it is right."""
    errs = []
    blk = entry(lines, "slot-" + slot)
    if not blk:
        return ["entry slot-%s missing" % slot]
    kl = kernel(blk)
    for word in ("quiet", "splash"):
        if not has_word(word, kl): errs.append("kernel line lacks %s" % word)
    for token in ("vt.global_cursor_default=0", "unitotem.slot=" + slot, "${unitotem_video}"):
        if token not in kl: errs.append("kernel line lacks %s" % token)
    idx_linux = next((i for i, l in enumerate(blk) if l.strip().startswith("linux ")), None)
    idx_gfx = next((i for i, l in enumerate(blk) if l.strip() == "set gfxpayload=keep"), None)
    idx_frame = next((i for i, l in enumerate(blk) if l.strip() == "unitotem_boot_frame " + slot), None)
    if idx_gfx is None or idx_linux is None or not idx_gfx < idx_linux:
        errs.append("set gfxpayload=keep is not before linux")
    if idx_frame is None or idx_linux is None or not idx_frame < idx_linux:
        errs.append("unitotem_boot_frame %s is not before linux" % slot)
    return errs


def check_ota_recovery(lines):
    """Errors of the ota-recovery entry, empty when it is right."""
    errs = []
    blk = entry(lines, "ota-recovery")
    if not blk:
        return ["entry ota-recovery missing"]
    kl = kernel(blk)
    for word in ("quiet", "splash"):
        if has_word(word, kl): errs.append("kernel line has %s" % word)
    for token in ("nomodeset", "unitotem.ota=1", "loglevel=3", "console=tty0"):
        if token not in kl: errs.append("kernel line lacks %s" % token)
    if not any(l.strip() == "unitotem_lowres" for l in blk):
        errs.append("unitotem_lowres not called")
    return errs


def check_recover(lines, slot):
    errs = []
    kl = kernel(entry(lines, "slot-%s-recover" % slot))
    if not kl: return ["entry slot-%s-recover missing" % slot]
    for token in ("nomodeset", "unitotem.ota=recover"):
        if token not in kl: errs.append("kernel line lacks %s" % token)
    return errs


def main():
    # The script itself and its output.
    with open(ENTRIES, encoding="utf-8") as f:
        src = f.read()
    res = subprocess.run(["sh", ENTRIES], capture_output=True, text=True)
    out = res.stdout
    lines = out.splitlines()
    check("sh runs the entries script with exit 0", res.returncode == 0, res.stderr)

    # Level.
    m = re.search(r"^# unitotem-grub-level: (\d+)\b", src, re.M)
    check("unitotem-grub-level line is present", "# unitotem-grub-level: 6" in src)
    check("unitotem-grub-level is an integer >= 6", bool(m) and int(m.group(1)) >= 6, m and m.group(1))

    # Menu entries and fallback numbers.
    ids = [eid for _, eid, _ in menu_ids(lines)]
    check("menu entries in order: slot-a, slot-b, slot-a-recover, slot-b-recover, ota-recovery",
          ids == ["slot-a", "slot-b", "slot-a-recover", "slot-b-recover", "ota-recovery"], ids)
    ota_num = ids.index("ota-recovery") if "ota-recovery" in ids else -1
    check("ota-recovery is number 4 and the last entry", ota_num == 4 and ids[-1] == "ota-recovery", ota_num)
    fb = re.findall(r'^\s*set fallback="([^"]*)"', out, re.M)
    check('set fallback lines are exactly "1 4", "0 4", "4"', fb == ["1 4", "0 4", "4"], fb)
    check("every fallback list ends with the ota-recovery number",
          all(v.split()[-1] == str(ota_num) for v in fb if v.split()), (fb, ota_num))

    # Slot entries.
    for slot in "ab":
        errs = check_slot(lines, slot)
        check("slot-%s entry: quiet splash, cursor, slot, video, gfxpayload and boot frame before linux" % slot,
              not errs, "; ".join(errs))

    # OTA entries.
    errs = check_ota_recovery(lines)
    check("ota-recovery entry: no quiet or splash, nomodeset, ota=1, loglevel=3, console=tty0, lowres", not errs, "; ".join(errs))
    for slot in "ab":
        errs = check_recover(lines, slot)
        check("slot-%s-recover entry: nomodeset and unitotem.ota=recover" % slot, not errs, "; ".join(errs))

    # Early block: everything before the first menu entry.
    first_menu = next((i for i, l in enumerate(lines) if re.match(r"^menuentry\b", l)), len(lines))
    early = "\n".join(lines[:first_menu])
    for token in ('$grub_platform" = efi', "terminal_output gfxterm", "${prefix}/logo/${unitotem_gfx}.png", "insmod png"):
        check("early block contains %s" % token, token in early)

    # Functions: defined before their first use.
    for name in ("unitotem_draw", "unitotem_boot_frame", "unitotem_lowres", "unitotem_slot_title"):
        def_idx = next((i for i, l in enumerate(lines) if re.match(r"^function %s\s*\{" % name, l)), None)
        uses = [i for i, l in enumerate(lines)
                if not l.lstrip().startswith("#") and not re.match(r"^function ", l) and has_word(name, l)]
        first_use = uses[0] if uses else None
        check("%s is defined before its first use" % name,
              def_idx is not None and first_use is not None and def_idx < first_use,
              (def_idx, first_use))

    # unitotem_draw: picture then clear.
    _, body = function_body(lines, "unitotem_draw")
    body = body or []
    i_bg = next((i for i, l in enumerate(body) if l.strip() == "background_image -m stretch \"$1\""), None)
    i_clr = next((i for i, l in enumerate(body) if l.strip() == "clear"), None)
    check("unitotem_draw: background_image -m stretch is followed by clear",
          i_bg is not None and i_clr is not None and i_bg < i_clr)

    # unitotem_lowres: picture dropped only inside the splash test.
    _, body = function_body(lines, "unitotem_lowres")
    body = body or []
    i_if = next((i for i, l in enumerate(body) if l.strip() == 'if [ -n "$unitotem_splash" ]; then'), None)
    inner = []
    if i_if is not None:
        for j in range(i_if + 1, len(body)):
            if body[j].strip() == "fi":
                inner = body[i_if + 1:j]
                break
    outside = [l for k, l in enumerate(body) if i_if is None or not (i_if < k <= i_if + len(inner) + 1)]
    check("unitotem_lowres: terminal_output console and bare background_image inside the splash test",
          any(l.strip() == "terminal_output console" for l in inner) and any(l.strip() == "background_image" for l in inner))
    check("unitotem_lowres: no picture drop outside the splash test",
          not any(l.strip() in ("terminal_output console", "background_image") for l in outside))

    # Slot titles: version cleared first, titles copied right after each call.
    _, body = function_body(lines, "unitotem_slot_title")
    body = body or []
    first_stmt = next((l.strip() for l in body if l.strip()), "")
    check("unitotem_slot_title starts by clearing unitotem_ver", first_stmt == "set unitotem_ver=", first_stmt)
    for slot_label, letter in (("ROOT_A", "a"), ("ROOT_B", "b")):
        call = "unitotem_slot_title %s %s" % (slot_label, letter.upper())
        idx = next((i for i, l in enumerate(lines) if l.strip() == call), None)
        nxt = lines[idx + 1].strip() if idx is not None and idx + 1 < len(lines) else ""
        check("titles copied into unitotem_title_%s right after %s" % (letter, call),
              nxt == 'set unitotem_title_%s="$unitotem_title"' % letter, nxt)

    # Defaults file.
    with open(DEFAULTS, encoding="utf-8") as f:
        dl = f.read().splitlines()
    check("grub-default: GRUB_TIMEOUT_STYLE=hidden", "GRUB_TIMEOUT_STYLE=hidden" in dl)
    check("grub-default: GRUB_TIMEOUT=1", "GRUB_TIMEOUT=1" in dl)

    # Syntax with grub-script-check (parses only).
    tool = shutil.which("grub-script-check")
    if tool is None:
        print("SKIP: grub-script-check not on PATH, syntax not checked")
    else:
        td = tempfile.mkdtemp(prefix="grub-entries-")
        try:
            path = os.path.join(td, "grub.cfg")
            with open(path, "w", encoding="utf-8") as f:
                f.write("set prefix=(hd0,gpt1)/unitotem-grub/grub\n" + out)
            r = subprocess.run([tool, path], capture_output=True, text=True)
            check("grub-script-check accepts the generated configuration", r.returncode == 0, (r.stdout + r.stderr).strip())
        finally:
            for name in os.listdir(td):
                os.remove(os.path.join(td, name))
            os.rmdir(td)

    # Mutation self-check: quiet back in the ota-recovery kernel line must be reported.
    mutated = out.replace("linux /unitotem/recovery-vmlinuz nomodeset loglevel=3",
                          "linux /unitotem/recovery-vmlinuz nomodeset quiet loglevel=3", 1)
    check("mutation: the ota-recovery kernel line was changed", mutated != out)
    check("mutation: quiet in ota-recovery is reported", len(check_ota_recovery(mutated.splitlines())) > 0)

    print("RESULT: %d passed, %d failed" % (ok, fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())

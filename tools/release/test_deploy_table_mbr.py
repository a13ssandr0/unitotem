#!/usr/bin/env python3
"""Host-side test of the partition table written at deploy: load_image of deploy/script/remote-deploy.sh converts the image table to MBR
for every Raspberry Pi (arm64, FIRMWARE=rpi, Pi 3 or not) and never for amd64; cmd_restore_table of deploy/script/ota-engine.sh sizes the
last partition for a GPT table (backup table kept) and for an MBR table (no backup table, 32-bit size field). Both functions are cut out
of the real script text and run in bash with fakes for every disk tool; the fakes log their calls. Nothing touches a disk.
What it does NOT prove: that sfdisk accepts the table on a real disk (test_image_lib.sh does that on loop disks).

  python3 tools/release/test_deploy_table_mbr.py
"""
import os, re, subprocess, tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEPLOY = open(os.path.join(ROOT, "deploy/script/remote-deploy.sh")).read()
ENGINE = open(os.path.join(ROOT, "deploy/script/ota-engine.sh")).read()
ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS:", name)
    else: fail += 1; print("FAIL:", name, extra)


def cut(text, name):
    m = re.search(r"^%s\(\) \{[^\n]*\n.*?^\}\n" % name, text, re.S | re.M)
    if not m:
        m = re.search(r"^%s\(\) \{.*\}$" % name, text, re.M)
    assert m, name + " not found"
    return m.group(0)


LOAD_IMAGE = cut(DEPLOY, "load_image")
ENGINE_FUNCS = "\n".join(cut(ENGINE, n) for n in ("parse_args", "need", "cmd_restore_table"))

# Fixture: a descriptor of the four-partition arm64 A/B layout (FIRMWARE, ROOT_A, ROOT_B, DATA), GPT unless SRC_TABLE says dos (the arm64
# image itself). The conversion fake logs CONVERTED only for a GPT descriptor, as the real image_table_dos returns 0 for a DOS one.
LOAD_HARNESS = r"""
set -u
declare -A P
P[MODEL]="${MODEL:-}"
ARCH="${ARCH_IN:-arm64}"; FIRMWARE="${FW_IN:-rpi}"; TRYBOOT_CAPABLE=1; PI3="${PI3_IN:-0}"
OPT_IMAGE="$WORK/image.img"; IMG_TMPFS="$WORK"
log() { echo "LOG: $*"; }
die() { echo "DIE: $*"; exit 1; }
echo "CALL ok" > /dev/null
image_open() { echo "CALL image_open" >> "$WORK/calls"; return 0; }
image_describe() {
    echo "CALL image_describe $2" >> "$WORK/calls"
    printf 'UNITOTEM_LAYOUT=2\nUNITOTEM_TABLE=%s\nUNITOTEM_DATA_PART=4\nUNITOTEM_BOOTFS_PART=1\n%s\nUNITOTEM_PART=1\nUNITOTEM_PART_LABEL=FIRMWARE\n\nUNITOTEM_PART=2\nUNITOTEM_PART_LABEL=ROOT_A\n\nUNITOTEM_PART=4\nUNITOTEM_PART_LABEL=DATA\n' "${SRC_TABLE:-gpt}" "${SYNTH_LINE:-}" > "$1/parts.manifest"
    printf 'label: %s\n' "${SRC_TABLE:-gpt}" > "$1/layout.sfdisk"
}
image_table_dos() {
    echo "CALL image_table_dos" >> "$WORK/calls"
    [ "$(awk -F': *' '/^label:/{print $2}' "$1/layout.sfdisk")" = gpt ] && echo "CONVERTED" >> "$WORK/calls"
    return 0
}
"""


def run_load(arch="arm64", fw="rpi", pi3=0, model="Raspberry Pi 4 Model B Rev 1.5", synth=False, src_table="gpt"):
    with tempfile.TemporaryDirectory() as td:
        open(os.path.join(td, "image.img"), "w").close()
        env = dict(os.environ, WORK=td, ARCH_IN=arch, FW_IN=fw, PI3_IN=str(pi3), MODEL=model, SRC_TABLE=src_table, SYNTH_LINE="UNITOTEM_SYNTH=1\n" if synth else "")
        # IMG_DESC comes from mktemp under IMG_TMPFS: the harness points it at the test directory
        script = LOAD_HARNESS + LOAD_IMAGE + "\nload_image\necho \"END rc=$? DATA=${P_DATA_PART:-} BOOTFS=${P_BOOTFS_PART:-} SYNTH=${P_SYNTH:-}\"\n"
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
        calls = open(os.path.join(td, "calls")).read() if os.path.exists(os.path.join(td, "calls")) else ""
        return r.stdout + r.stderr, calls, r.returncode


MSG = "LOG: Target is a %s: the partition table is written as MBR, converted from GPT."
MSG_DOS = "LOG: Target is a %s: the partition table is written as MBR, the image's own table."

out, calls, rc = run_load(model="Raspberry Pi 4 Model B Rev 1.5")
check("Pi 4 (arm64, rpi, not Pi 3): the table is converted", "CALL image_table_dos" in calls and rc == 0, out + calls)
check("Pi 4: the message names the exact model", MSG % "Raspberry Pi 4 Model B Rev 1.5" in out, out)
check("Pi 4: the partition numbers are read after the conversion", "END rc=0 DATA=4 BOOTFS=1" in out, out)

out, calls, rc = run_load(model="Raspberry Pi 5 Model B Rev 1.0")
check("Pi 5: the table is converted", "CALL image_table_dos" in calls and MSG % "Raspberry Pi 5 Model B Rev 1.0" in out, out + calls)

out, calls, rc = run_load(pi3=1, model="Raspberry Pi 3 Model B Rev 1.2")
check("Pi 3: the table is converted, with the exact model", "CALL image_table_dos" in calls and MSG % "Raspberry Pi 3 Model B Rev 1.2" in out, out + calls)

out, calls, rc = run_load(pi3=1, model="Raspberry Pi Zero 2 W Rev 1.0")
check("Pi Zero 2 W: the table is converted", "CALL image_table_dos" in calls and MSG % "Raspberry Pi Zero 2 W Rev 1.0" in out, out + calls)

out, calls, rc = run_load(model="Raspberry Pi 4 Model B Rev 1.5", src_table="dos")
check("Pi 4, DOS image: the table is not converted (already MBR), the log says so", "CALL image_table_dos" in calls and "CONVERTED" not in calls and MSG_DOS % "Raspberry Pi 4 Model B Rev 1.5" in out and rc == 0, out + calls)
check("Pi 4, DOS image: the partition numbers are read from the MBR image", "END rc=0 DATA=4 BOOTFS=1" in out, out)

out, calls, rc = run_load(pi3=1, model="Raspberry Pi 3 Model B Rev 1.2", src_table="dos")
check("Pi 3, DOS image: written as the image's own MBR", "CONVERTED" not in calls and MSG_DOS % "Raspberry Pi 3 Model B Rev 1.2" in out, out + calls)

out, calls, rc = run_load(arch="amd64", fw="uefi", model="")
check("amd64 UEFI: the table is not converted (GPT)", "CALL image_table_dos" not in calls and "MBR" not in out and rc == 0, out + calls)

out, calls, rc = run_load(arch="amd64", fw="bios", model="")
check("amd64 BIOS: the table is not converted (GPT)", "CALL image_table_dos" not in calls and rc == 0, out + calls)


# restore-table: the table as the image has it, after image_table_dos (dos) or as written (gpt)
DOS_TABLE = """label: dos
label-id: 0x12345678
unit: sectors

/dev/x1 : start=2048, size=131072, type=c
/dev/x2 : start=133120, size=600000, type=83
/dev/x3 : start=733120, size=300000, type=83
/dev/x4 : start=1033120, size=400000, type=83
"""
GPT_TABLE = """label: gpt
label-id: 12345678-1234-1234-1234-123456789abc
unit: sectors
first-lba: 2048
last-lba: 7864286

/dev/x1 : start=2048, size=131072, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=AAAAAAAA-0000-0000-0000-000000000001, name="FIRMWARE"
/dev/x2 : start=133120, size=600000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-0000-0000-0000-000000000002, name="ROOT_A"
/dev/x3 : start=733120, size=300000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-0000-0000-0000-000000000003, name="ROOT_B"
/dev/x4 : start=1033120, size=400000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=AAAAAAAA-0000-0000-0000-000000000004, name="DATA"
"""

ENGINE_HARNESS = r"""
set -uo pipefail
W="$WORK"
fail() { echo "ENGINE-FAIL: $*"; exit 3; }
log() { echo "LOG: $*"; }
ota_status_set() { :; }
resolve_disk() { echo "$1"; }
blockdev() { echo "$DISK_SECTORS"; }
umount() { :; }
partprobe() { :; }
partx() { :; }
udevadm() { :; }
mark_point_of_no_return() { :; }
dd() { echo "CALL dd" >> "$W/calls"; cat > /dev/null; }
sfdisk() { echo "CALL sfdisk $*" >> "$W/calls"; cat > "$W/sfdisk.in"; }
declare -A ARG
"""


def run_restore(table, disk_sectors, tail="4", bootcode=""):
    with tempfile.TemporaryDirectory() as td:
        import base64
        b64 = base64.b64encode(table.encode()).decode()
        args = "--disk /dev/fake --table-b64 '%s' --tail-part %s" % (b64, tail)
        if bootcode:
            args += " --bootcode-b64 '%s'" % base64.b64encode(bootcode.encode()).decode()
        script = ENGINE_HARNESS + ENGINE_FUNCS + "\ncmd_restore_table " + args + "\necho \"END rc=$?\"\n"
        env = dict(os.environ, WORK=td, DISK_SECTORS=str(disk_sectors))
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
        written = open(os.path.join(td, "sfdisk.in")).read() if os.path.exists(os.path.join(td, "sfdisk.in")) else ""
        calls = open(os.path.join(td, "calls")).read() if os.path.exists(os.path.join(td, "calls")) else ""
        return r.stdout + r.stderr, written, calls


def tail_size(written):
    m = re.search(r"^/dev/x4 : .*size=\s*(\d+)", written, re.M)
    return int(m.group(1)) if m else None


DISK = 7864320  # 4 GiB in 512-byte sectors
out, written, calls = run_restore(DOS_TABLE, DISK)
check("MBR restore: the DATA partition runs to the disk end (no backup table kept)", tail_size(written) == DISK - 1033120, out + written)
check("MBR restore: no last-lba line is written, label dos kept", "label: dos" in written and "last-lba" not in written, written)
check("MBR restore: the other partitions are written unchanged", "/dev/x2 : start=133120, size=600000" in written, written)
check("MBR restore: no boot code without --bootcode-b64 (the MBR boot code is not written)", "CALL dd" not in calls, calls)
check("MBR restore: sfdisk is run with --force --no-reread", "CALL sfdisk --force --no-reread" in calls, calls)

out, written, calls = run_restore(GPT_TABLE, DISK, tail="4")
check("GPT restore: the DATA partition keeps 34 sectors for the backup table", tail_size(written) == DISK - 1033120 - 34, out + written)

out, written, calls = run_restore(DOS_TABLE, 2 ** 33)  # 4 TiB disk: the MBR size field caps the tail at 2 TiB - 1 sector
check("MBR restore on a disk above 2 TiB: the tail is capped at 32 bits", tail_size(written) == 4294967295, out + written)

out, written, calls = run_restore(DOS_TABLE, 1000000)
check("MBR restore: a disk smaller than the partitions before DATA is refused", "ENGINE-FAIL" in out and "disk too small" in out, out)


# Minimal image: the descriptor is synthesized by image_describe (UNITOTEM_SYNTH=1): load_image reads the flag; the target's ROOT_A
# restore is the one that grows (remote-deploy.sh passes --fstype ext4 --grow 1 for it).
out, calls, rc = run_load(synth=True)
check("minimal image: load_image reads UNITOTEM_SYNTH=1", "SYNTH=1" in out and rc == 0, out)
out, calls, rc = run_load(synth=False)
check("full-size image: UNITOTEM_SYNTH is not set", "SYNTH=\n" in out or out.rstrip().endswith("SYNTH="), out)
REST = [l for l in DEPLOY.split("\n") if "grow_args" in l]
check("remote-deploy: the grow flags are set only for ROOT_A of a synthesized image (static text check)",
      any('[ "${P_SYNTH:-0}" = 1 ] && [ "$label" = ROOT_A ]' in l for l in REST) and any("--fstype ext4 --grow 1" in l for l in REST)
      and "restore-part --disk" in DEPLOY and "--data-port '${OPT_PORT}' ${grow_args}\"" in DEPLOY)

# Synthesized table (minimal image, 512 MiB slot): FIRMWARE, ROOT_A (slot), ROOT_B (slot), DATA (nominal 256 MiB)
SL = 1048576
SYNTH_GPT = """label: gpt
label-id: 12345678-1234-1234-1234-123456789abc
unit: sectors
first-lba: 2048
last-lba: 7864286

/dev/x1 : start=2048, size=131072, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="FIRMWARE"
/dev/x2 : start=133120, size=%d, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ROOT_A"
/dev/x3 : start=1181696, size=%d, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ROOT_B"
/dev/x4 : start=2230272, size=524288, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="DATA"
""" % (SL, SL)
out, written, calls = run_restore(SYNTH_GPT, DISK, tail="4")
check("synthesized GPT restore: DATA runs to the disk end, minus the backup table", tail_size(written) == DISK - 2230272 - 34, out + written)
check("synthesized GPT restore: ROOT_A and ROOT_B keep the slot size", "/dev/x2 : start=133120, size=%d" % SL in written and "/dev/x3 : start=1181696, size=%d" % SL in written, written)
out, written, calls = run_restore(SYNTH_GPT, 2 * 1048576 + 2230272 + 1000, tail="4")
check("synthesized GPT restore on a disk just above the DATA start: tail computed, not negative", tail_size(written) == 2 * 1048576 + 1000 - 34 and "END rc=0" in out, out + written)

# The same layout as MBR (every Raspberry Pi): four primaries, no backup table
SYNTH_DOS = """label: dos
label-id: 0x12345678
unit: sectors

/dev/x1 : start=2048, size=131072, type=c
/dev/x2 : start=133120, size=%d, type=83
/dev/x3 : start=1181696, size=%d, type=83
/dev/x4 : start=2230272, size=524288, type=83
""" % (SL, SL)
out, written, calls = run_restore(SYNTH_DOS, DISK, tail="4")
check("synthesized MBR restore: DATA runs to the disk end (no backup table)", tail_size(written) == DISK - 2230272, out + written)
check("synthesized MBR restore: the slot partitions are written unchanged", "/dev/x2 : start=133120, size=%d" % SL in written and "/dev/x3 : start=1181696, size=%d" % SL in written, written)


# restore-part of the engine (cut from the script): the grow of a minimal image's ROOT_A. Fakes: partclone, dd, e2fsck, resize2fs, blockdev,
# unxz are shell functions that log their calls; two lines are replaced: the /dev/tcp open (stdin is /dev/null) and the block-device guard
# (the test has no block device). Nothing is written.
RP = cut(ENGINE, "cmd_restore_part")
RP_LINES = RP.replace('    exec 4<>"/dev/tcp/${ARG[data-host]}/${ARG[data-port]}"', '    exec 4</dev/null')
RP_LINES = RP_LINES.replace('    [ -b "$part_dev" ] || fail "partition not found: $part_dev"', '    :')
check("restore-part: the two replaced lines are found in the engine", RP_LINES.count("exec 4</dev/null") == 1 and RP_LINES.count("    :\n") >= 1 and RP != RP_LINES)
RP_HARNESS = r"""
set -Eeuo pipefail
W="$WORK"
declare -A ARG
log() { echo "LOG: $*"; }
warn() { echo "WARNING: $*"; }
fail() { echo "ENGINE-FAIL: $*"; exit 3; }
ota_status_set() { :; }
OTA_PCT_FILE=/dev/null
resolve_disk() { echo "$1"; }
pdev_target() { echo "/dev/fakep$2"; }
blockdev() { echo "$PART_SECTORS"; }
mkdir() { :; }
unxz() { cat > /dev/null; cat /dev/null; }
dd() { echo "CALL dd $*" >> "$W/calls"; cat > /dev/null; }
partclone.restore() { echo "CALL partclone.restore $*" >> "$W/calls"; cat > /dev/null; return "${PC_RC:-0}"; }
e2fsck() { echo "CALL e2fsck $*" >> "$W/calls"; return "${E2_RC:-0}"; }
resize2fs() { echo "CALL resize2fs $*" >> "$W/calls"; return "${RS_RC:-0}"; }
"""
def run_rp(args, part_sectors=10485760, e2_rc=0, rs_rc=0, pc_rc=0):
    with tempfile.TemporaryDirectory() as td:
        env = dict(os.environ, WORK=td, PART_SECTORS=str(part_sectors), E2_RC=str(e2_rc), RS_RC=str(rs_rc), PC_RC=str(pc_rc))
        script = RP_HARNESS + ENGINE_PARSE + RP_LINES + "\ncmd_restore_part " + args + "\necho \"END rc=$?\"\n"
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
        calls = open(os.path.join(td, "calls")).read() if os.path.exists(os.path.join(td, "calls")) else ""
        return r.stdout + r.stderr, calls
ENGINE_PARSE = "\n".join(cut(ENGINE, n) for n in ("parse_args", "need"))
BASE = "--disk /dev/fake --part 2 --cloner extfs --comp xz --used-bytes 1000000000 --data-host 127.0.0.1 --data-port 9"
GROW = BASE + " --fstype ext4 --grow 1"
out, calls = run_rp(GROW)
check("grow: e2fsck -fy then resize2fs on the partition, rc 0", "END rc=0" in out and "CALL e2fsck -fy /dev/fakep2" in calls and calls.index("CALL e2fsck") < calls.index("CALL resize2fs /dev/fakep2"), out + calls)
check("grow: UNITOTEM_PART_RESTORED is reported", "UNITOTEM_PART_RESTORED=2" in out, out)
out, calls = run_rp(GROW, e2_rc=1)
check("grow: e2fsck repaired (rc 1) is accepted, resize2fs runs", "END rc=0" in out and "CALL resize2fs" in calls, out + calls)
out, calls = run_rp(GROW, e2_rc=4)
check("grow: e2fsck with uncorrected errors (rc 4) stops the restore (no END line), no resize", "END rc=" not in out and "ENGINE-FAIL: e2fsck found uncorrected errors" in out and "CALL resize2fs" not in calls, out + calls)
out, calls = run_rp(GROW, rs_rc=1)
check("grow: a failed resize2fs is a warning line, the restore still succeeds", "END rc=0" in out and "WARNING: resize2fs failed" in out and "UNITOTEM_PART_RESTORED=2" in out, out)
out, calls = run_rp(BASE)
check("no grow: e2fsck is run (its result ignored as before), no resize2fs", "END rc=0" in out and "CALL e2fsck -fy /dev/fakep2" in calls and "CALL resize2fs" not in calls, out + calls)
out, calls = run_rp(BASE + " --cloner dd --fstype ext4 --grow 1", part_sectors=10485760)
check("cloner dd (BIOS): no fsck, no resize", "END rc=0" in out and "CALL e2fsck" not in calls and "CALL resize2fs" not in calls and "CALL dd" in calls, out + calls)
out, calls = run_rp(GROW, part_sectors=10485760)
check("grow into a slot larger than the stream: -C (no size check) is passed", "CALL partclone.restore -C -o /dev/fakep2" in calls, calls)
out, calls = run_rp(GROW, part_sectors=2000000)
check("the stream does not fit the partition (used + margin): no -C, partclone checks", "CALL partclone.restore -o /dev/fakep2" in calls and "-C" not in calls.split("partclone.restore")[1].split("\n")[0], calls)

print("%d passed, %d failed" % (ok, fail))
raise SystemExit(0 if fail == 0 else 1)

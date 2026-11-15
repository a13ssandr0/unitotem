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

# Fixture: a descriptor of the four-partition arm64 A/B layout (FIRMWARE, ROOT_A, ROOT_B, DATA); the conversion fake keeps a marker.
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
    printf 'UNITOTEM_LAYOUT=2\nUNITOTEM_TABLE=gpt\nUNITOTEM_DATA_PART=4\nUNITOTEM_BOOTFS_PART=1\n\nUNITOTEM_PART=1\nUNITOTEM_PART_LABEL=FIRMWARE\n\nUNITOTEM_PART=2\nUNITOTEM_PART_LABEL=ROOT_A\n\nUNITOTEM_PART=4\nUNITOTEM_PART_LABEL=DATA\n' > "$1/parts.manifest"
    echo gpt > "$1/layout.sfdisk"
}
image_table_dos() { echo "CALL image_table_dos" >> "$WORK/calls"; echo dos > "$1/converted"; }
"""


def run_load(arch="arm64", fw="rpi", pi3=0, model="Raspberry Pi 4 Model B Rev 1.5"):
    with tempfile.TemporaryDirectory() as td:
        open(os.path.join(td, "image.img"), "w").close()
        env = dict(os.environ, WORK=td, ARCH_IN=arch, FW_IN=fw, PI3_IN=str(pi3), MODEL=model)
        # IMG_DESC comes from mktemp under IMG_TMPFS: the harness points it at the test directory
        script = LOAD_HARNESS + LOAD_IMAGE + "\nload_image\necho \"END rc=$? DATA=${P_DATA_PART:-} BOOTFS=${P_BOOTFS_PART:-}\"\n"
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
        calls = open(os.path.join(td, "calls")).read() if os.path.exists(os.path.join(td, "calls")) else ""
        return r.stdout + r.stderr, calls, r.returncode


MSG = "LOG: Target is a %s: the partition table is written as MBR."

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

print("%d passed, %d failed" % (ok, fail))
raise SystemExit(0 if fail == 0 else 1)

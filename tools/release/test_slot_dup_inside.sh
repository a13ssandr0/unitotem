#!/bin/bash
# Runs INSIDE the privileged container of test_slot_dup.sh. Only /dev/loop* devices are touched: every blkid query goes
# through a shim that reads the partitions of the test loop only, and findmnt reports the test's slot A as the root.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends gdisk fdisk parted e2fsprogs dosfstools util-linux \
    coreutils dash bash python3 partclone pv procps >/dev/null 2>&1 || { echo "apt failed"; exit 1; }
W=/work; SCR=/tmp/agent-S-w3; SCN=/work/scn.img
mkdir -p "$SCR/shim" /mnt/b2 /mnt/s2 /mnt/s3 || exit 1
mount -t devtmpfs devtmpfs /dev 2>/dev/null || { echo "cannot mount devtmpfs"; exit 1; }
export LOOP= SHIM_DEVS= ROOT_SRC=
declare -A SP=() SF=()
SEC=setup; pass=0; failn=0; RC=0; OUT=""

cleanup() {
    for m in /mnt/b2 /mnt/s2 /mnt/s3; do umount "$m" 2>/dev/null; done
    for f in "$W"/*.img; do for l in $(losetup -j "$f" -O NAME -n 2>/dev/null); do losetup -d "$l" 2>/dev/null; done; done
}
trap cleanup EXIT; trap 'exit 1' TERM INT

ok()  { SP[$SEC]=$(( ${SP[$SEC]:-0} + 1 )); pass=$((pass + 1)); echo "PASS: [$SEC] $1"; }
bad() { SF[$SEC]=$(( ${SF[$SEC]:-0} + 1 )); failn=$((failn + 1)); echo "FAIL: [$SEC] $1"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
hasres() { [[ "$OUT" == *"$1"* ]]; }
nores() { ! [[ "$OUT" == *"$1"* ]]; }
eqv() { local d="$1" got="$2" want="$3"; if [ "$got" = "$want" ]; then ok "$d"; else bad "$d (got '$got', want '$want')"; fi; }

# ---- blkid and findmnt shims: the real tools, restricted to the loop partitions of this test ----
cat > "$SCR/shim/blkid" <<'SHIM'
#!/bin/bash
# blkid -t TAG=VALUE: the partitions in $SHIM_DEVS carrying it, rc 2 when none (as blkid); other queries need a device.
if [ "${1:-}" = -t ]; then
    tag=${2%%=*}; val=${2#*=}; found=2
    for d in ${SHIM_DEVS:-}; do
        [ -b "$d" ] || continue
        if [ "$(/usr/sbin/blkid -c /dev/null -o value -s "$tag" "$d" 2>/dev/null)" = "$val" ]; then echo "$d"; found=0; fi
    done
    exit $found
fi
case " $* " in *" /dev/loop"*) exec /usr/sbin/blkid -c /dev/null "$@" ;; esac
exit 2
SHIM
cat > "$SCR/shim/findmnt" <<'SHIM'
#!/bin/bash
# findmnt -no SOURCE /: the running root, which the test sets to slot A; anything else is the real findmnt.
if [ "${1:-}" = -no ] && [ "${2:-}" = SOURCE ] && [ "${3:-}" = / ]; then echo "${ROOT_SRC:-overlay}"; exit 0; fi
exec /usr/bin/findmnt "$@"
SHIM
chmod +x "$SCR/shim/blkid" "$SCR/shim/findmnt"
export PATH="$SCR/shim:$PATH"

# ---- the driver (unitotem-update clone_into_slot, the old method) and the slot_dev reader ----
cat > "$SCR/drv.py" <<'PY'
#!/usr/bin/env python3
# Test driver, runs in the test container only.
#   clone DEV SRC : clone_into_slot of unitotem-update, fed by partclone.extfs as do_repair does
#   old   DEV SRC : the previous method, partclone.extfs | partclone.restore straight onto DEV
# --throttle: pv -qL 8m between source and consumer. --crash NAME: os._exit at that crashpoint (clone only).
# --kill-at F: SIGKILL of the whole process group once F of the stream has been produced (the source's wchar: pv's
# counters miss the spliced bytes). A power cut of the pipeline.
# --kill-src-at F: SIGKILL of the source stages only, at F of the stream. --label: the new label of the clone.
import argparse, importlib.machinery, importlib.util, os, re, signal, subprocess, tempfile, threading, time

loader = importlib.machinery.SourceFileLoader("uu", "/repo/unitotem/files/unitotem-update")
spec = importlib.util.spec_from_loader("uu", loader)
uu = importlib.util.module_from_spec(spec)
loader.exec_module(uu)

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["clone", "old"])
ap.add_argument("dev")
ap.add_argument("src")
ap.add_argument("--label", default="ROOT_B")
ap.add_argument("--throttle", action="store_true")
ap.add_argument("--crash", default="")
ap.add_argument("--kill-at", type=float, default=0.0)
ap.add_argument("--kill-src-at", type=float, default=0.0)
a = ap.parse_args()
os.setpgid(0, 0)

def wchar(pid):
    try:
        with open(f"/proc/{pid}/io") as f:
            return int(re.search(r"^wchar: (\d+)", f.read(), re.M).group(1))
    except (OSError, AttributeError):
        return None

S = len(subprocess.run(["partclone.extfs", "-c", "-F", "-s", a.src, "-o", "-"], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, check=True).stdout)          # size of the stream of the source
stages = []

def start_source():
    src = subprocess.Popen(["partclone.extfs", "-c", "-F", "-s", a.src, "-o", "-"], stdout=subprocess.PIPE)
    stages.append(src)
    last = src
    if a.throttle:
        pv = subprocess.Popen(["pv", "-qL", "8m"], stdin=src.stdout, stdout=subprocess.PIPE)
        src.stdout.close()
        stages.append(pv)
        last = pv
    return last

def watch(last, frac, action):
    thr = int(S * frac)
    end = time.time() + 300
    while time.time() < end:
        w = wchar(last.pid)
        if w is None:
            return
        if w >= thr:
            action()
            return
        time.sleep(0.01)

def kill_group():
    os.killpg(os.getpgrp(), signal.SIGKILL)

def kill_sources():
    for s in stages:
        s.kill()

if a.crash:
    def crashpoint(conf, name):
        if name == a.crash:
            os._exit(1)
    uu.crashpoint = crashpoint

conf = dict(uu.CONF_DEFAULTS)
last = start_source()
if a.kill_at:
    threading.Thread(target=watch, args=(stages[0], a.kill_at, kill_group), daemon=True).start()
if a.kill_src_at:
    threading.Thread(target=watch, args=(stages[0], a.kill_src_at, kill_sources), daemon=True).start()

if a.mode == "clone":
    with tempfile.TemporaryFile() as serr:
        try:
            uu.clone_into_slot(conf, last.stdout, a.dev, a.label, serr)
        except uu.Fail as e:
            kill_sources()
            for s in stages:
                s.wait()
            print(f"RESULT fail {e.code}: {e}")
            raise SystemExit(3)
        except Exception as e:
            kill_sources()
            for s in stages:
                s.wait()
            print(f"RESULT error {e!r}")
            raise SystemExit(4)
    for s in stages:
        s.wait()
    if stages[0].returncode:                       # as do_repair: the source's exit status counts
        print(f"RESULT fail write-failed: partclone read rc={stages[0].returncode}")
        raise SystemExit(3)
    print("RESULT ok")
    raise SystemExit(0)
else:
    rs = subprocess.Popen(["partclone.restore", "-C", "-s", "-", "-o", a.dev], stdin=last.stdout)
    last.stdout.close()
    rc = rs.wait()
    for s in stages:
        s.wait()
    print(f"RESULT {'ok' if rc == 0 else 'fail'} restore rc={rc}")
    raise SystemExit(0 if rc == 0 else 3)
PY
cat > "$SCR/sel.py" <<'PY'
#!/usr/bin/env python3
# Prints unitotem-update's slot_dev for both slots (test container only).
import importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("uu", "/repo/unitotem/files/unitotem-update")
spec = importlib.util.spec_from_loader("uu", loader)
uu = importlib.util.module_from_spec(spec)
loader.exec_module(uu)
print(f"a={uu.slot_dev('a')} b={uu.slot_dev('b')}")
PY

# ---- deploy/ota-engine.sh: sourced, its ERR trap cleared; log/warn to a file; the boot stubs of test_slot_pick ----
. /repo/deploy/ota-engine.sh
set +Eeuo pipefail
trap - ERR
WARNLOG="$SCR/warn.log"; : > "$WARNLOG"
log()  { echo "log: $*" >> "$WARNLOG"; }
warn() { echo "warn: $*" >> "$WARNLOG"; }
kmsg() { :; }
modprobe() { return 0; }
udevadm() { return 0; }
check_flag_file() { return 1; }
bootcount_gate() { BOOTCOUNT_RECOVERY=0; }
SERVE_CALLS=(); BOOTCOUNT_RECOVERY=0
cmd_serve_fallback() { SERVE_CALLS+=("$*"); return 0; }
cmdline_get() {                                    # the test's command line (the engine reads /proc/cmdline)
    local tok
    for tok in $(cat "$SCR/cmdline"); do case "$tok" in "$1="*) printf '%s\n' "${tok#*=}"; return 0 ;; esac; done
    return 1
}
export OTA_CONF_PARAM="$SCR/param.conf" OTA_BOOTFS_MNT="$SCR/boot" TEST_CMDLINE="$SCR/cmdline"

# ---- helpers ----
wait_nodes() {                                     # wait_nodes LOOP: the partition nodes of a loop device appear
    local i; for i in $(seq 1 50); do [ -b "${1}p2" ] && [ -b "${1}p4" ] && return 0; sleep 0.2; done; return 1
}
attach() {                                         # attach FILE: LOOP, the shim's partitions and the running root (slot A)
    LOOP=$(losetup --find --show --partscan "$1") || return 1
    wait_nodes "$LOOP" || return 1
    SHIM_DEVS="${LOOP}p1 ${LOOP}p2 ${LOOP}p3 ${LOOP}p4"; ROOT_SRC="${LOOP}p2"
    export LOOP SHIM_DEVS ROOT_SRC
}
detach() {
    local m; for m in /mnt/b2 /mnt/s2 /mnt/s3; do mountpoint -q "$m" && umount "$m"; done
    losetup -d "$LOOP"; LOOP=""
}
fresh() { cp --sparse=always "$1" "$SCN" && attach "$SCN"; }      # a copy of a base image, attached
lbl()  { blkid -o value -s LABEL "$1" 2>/dev/null || true; }
typ()  { blkid -o value -s TYPE "$1" 2>/dev/null || true; }
uuid() { blkid -o value -s UUID "$1" 2>/dev/null || true; }
findlabel() { blkid -t "LABEL=$1" -o device 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//' || true; }
hashp() { sha256sum < "$1" | cut -d' ' -f1; }
drv() {                                            # drv ARGS: drv.py in its own process group; RC its status, OUT its RESULT
    python3 -I "$SCR/drv.py" "$@" > "$SCR/out.txt" 2> "$SCR/err.txt" &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RC=124; echo "driver hung: killed"
    else
        wait "$pid"; RC=$?
    fi
    OUT=$(cat "$SCR/out.txt")
}
selv() { python3 -I "$SCR/sel.py" 2>/dev/null || echo "sel failed"; }
premount() {                                       # premount LABEL SLOT: the real cmd_init_premount; PM_RC, PM_SERVE
    rm -f "$SCR/param.conf"
    printf 'root=LABEL=%s ro quiet unitotem.slot=%s\n' "$1" "$2" > "$SCR/cmdline"
    SERVE_CALLS=(); cmd_init_premount; PM_RC=$?; PM_SERVE=${#SERVE_CALLS[@]}
}
pinned() { cat "$SCR/param.conf" 2>/dev/null || true; }
noleft() {                                         # no clone or source process of the killed run is left
    local i
    for i in $(seq 1 20); do
        if ! pgrep -x pv >/dev/null && ! pgrep -x partclone.extfs >/dev/null && ! pgrep -x 'partclone.resto' >/dev/null; then ok "$1"; return; fi
        sleep 0.25
    done
    bad "$1"
}
finish_checks() {                                  # finish_checks PREFIX H0: relabel and fsck as do_repair, compare with the source
    local pre=$1 h0=$2 rc
    tune2fs -f -U random -L ROOT_B "${LOOP}p3" >/dev/null 2>&1; rc=$?
    chk "$pre: tune2fs -U random -L ROOT_B (as do_repair)" [ "$rc" = 0 ]
    e2fsck -fn "${LOOP}p3" >/dev/null 2>&1; rc=$?
    chk "$pre: e2fsck -fn on the copy clean (rc $rc)" [ "$rc" = 0 ]
    e2fsck -fn "${LOOP}p2" >/dev/null 2>&1; rc=$?
    chk "$pre: e2fsck -fn on the source clean (rc $rc)" [ "$rc" = 0 ]
    mount -o ro "${LOOP}p2" /mnt/s2 && mount -o ro "${LOOP}p3" /mnt/s3
    chk "$pre: diff -r of the copy and the source" diff -r /mnt/s2 /mnt/s3
    chk "$pre: zero region of the source is zero in the copy" bash -c \
        '[ "$(stat -c %s /mnt/s3/zeros.bin)" = 4194304 ] && [ "$(tr -d "\0" < /mnt/s3/zeros.bin | wc -c)" = 0 ]'
    umount /mnt/s2 /mnt/s3
    chk "$pre: copy UUID differs from the source" bash -c "[ -n '$(uuid "${LOOP}p3")' ] && [ '$(uuid "${LOOP}p3")' != '$(uuid "${LOOP}p2")' ]"
    eqv "$pre: copy label ROOT_B" "$(lbl "${LOOP}p3")" ROOT_B
    eqv "$pre: source label ROOT_A" "$(lbl "${LOOP}p2")" ROOT_A
    eqv "$pre: source untouched (hash before/after)" "$(hashp "${LOOP}p2")" "$h0"
}

# ---- fixtures: the slot contents (random data, a zero region, the version stamp) and the base images ----
rm -rf /tmp/agent-S-w3/content
mkdir -p /tmp/agent-S-w3/content/data /tmp/agent-S-w3/content/usr/share/unitotem
for i in 1 2 3 4 5; do head -c $((5 * 1024 * 1024)) /dev/urandom > /tmp/agent-S-w3/content/data/r$i.bin; done
echo 2026.11.99-slotdup > /tmp/agent-S-w3/content/usr/share/unitotem/release-version

mkbase() {                                         # mkbase LAYOUT FEAT P3_MIB FILE: partitions p1 EFI, p2 ROOT_A, p3 ROOT_B, p4 DATA
    local layout=$1 feat=$2 p3=$3 file=$4 L f=()
    truncate -s 0 "$file"; truncate -s 256M "$file"
    if [ "$layout" = gpt ]; then
        sgdisk -Z "$file" >/dev/null
        sgdisk -n 1:0:+32M -t 1:ef00 -c 1:EFI "$file" >/dev/null
        sgdisk -n 2:0:+48M -t 2:8300 -c 2:ROOT_A "$file" >/dev/null
        sgdisk -n 3:0:+${p3}M -t 3:8300 -c 3:ROOT_B "$file" >/dev/null
        sgdisk -n 4:0:0 -t 4:8300 -c 4:DATA "$file" >/dev/null
    else
        printf 'label: dos\n,32M,c\n,48M,83\n,%sM,83\n,,83\n' "$p3" | sfdisk -q "$file" >/dev/null 2>&1
        sfdisk -q --disk-id "$file" 0x5a1c0003 >/dev/null 2>&1
    fi
    [ "$feat" = nocsum ] && f=(-O ^metadata_csum)
    L=$(losetup --find --show --partscan "$file") || return 1
    wait_nodes "$L" || { losetup -d "$L"; return 1; }
    mkfs.fat -F32 -n EFI "${L}p1" >/dev/null
    mkfs.ext4 -q -F "${f[@]}" -L ROOT_A "${L}p2" || { losetup -d "$L"; return 1; }
    mkfs.ext4 -q -F "${f[@]}" -L ROOT_B "${L}p3" || { losetup -d "$L"; return 1; }
    mkfs.ext4 -q -F -L DATA "${L}p4" || { losetup -d "$L"; return 1; }
    mount "${L}p2" /mnt/b2 && cp -a /tmp/agent-S-w3/content/. /mnt/b2/ \
        && dd if=/dev/zero of=/mnt/b2/zeros.bin bs=1M count=4 2>/dev/null
    sync; umount /mnt/b2
    e2fsck -fn "${L}p2" >/dev/null 2>&1; local rc=$?
    losetup -d "$L"
    [ "$rc" = 0 ]
}

# ---- the engine's own copy of the slot selection on the real blkid and sysfs (no fixture) ----
SEC=setup
echo "start $(date -u +%H:%M:%S)"

run_cfg() {                                        # run_cfg LAYOUT FEAT
    local layout=$1 feat=$2 cfg="$1-$2" base small st H0 p3
    base=/work/base-$cfg.img; small=/work/small-$cfg.img
    SEC=setup
    if mkbase "$layout" "$feat" 48 "$base"; then ok "$cfg: base image (p2 ROOT_A 48 MiB, p3 ROOT_B 48 MiB) built"
    else bad "$cfg: base image built"; return; fi
    if mkbase "$layout" "$feat" 24 "$small"; then ok "$cfg: small base image (p3 ROOT_B 24 MiB) built"
    else bad "$cfg: small base image built"; return; fi

    # R. the incident with the old method, killed at 30 % of the stream
    SEC=R
    fresh "$base"; H0=$(hashp "${LOOP}p2")
    drv old "${LOOP}p3" "${LOOP}p2" --throttle --kill-at 0.3
    chk "$cfg R: old method killed at 30 % (rc $RC)" [ "$RC" != 0 ]
    chk "$cfg R: no RESULT of a finished copy" nores "RESULT ok"
    noleft "$cfg R: no pv or partclone left after the kill"
    eqv "$cfg R: two LABEL=ROOT_A devices (the bug)" "$(findlabel ROOT_A)" "${LOOP}p2 ${LOOP}p3"
    eqv "$cfg R: same UUID on both (the bug)" "$(uuid "${LOOP}p3")" "$(uuid "${LOOP}p2")"
    eqv "$cfg R: slot_pick ROOT_A is p2" "$(slot_pick ROOT_A)" "${LOOP}p2"
    eqv "$cfg R: slot_dev a=p2 b=p3" "$(selv)" "a=${LOOP}p2 b=${LOOP}p3"
    eqv "$cfg R: slot_pick ROOT_B is none (p3 carries ROOT_A)" "$(slot_pick ROOT_B 2>/dev/null || true)" ""
    : > "$WARNLOG"
    heal_dup_label ROOT_A "${LOOP}p2"
    eqv "$cfg R: heal_dup_label relabels p3 ROOT_STALE" "$(lbl "${LOOP}p3")" ROOT_STALE
    eqv "$cfg R: one LABEL=ROOT_A after the heal (p2)" "$(findlabel ROOT_A)" "${LOOP}p2"
    chk "$cfg R: heal logs one warning naming p3" bash -c "[ \"\$(grep -c 'warn: duplicate label ROOT_A on ${LOOP}p3' '$WARNLOG')\" = 1 ]"
    eqv "$cfg R: source untouched by the heal (hash)" "$(hashp "${LOOP}p2")" "$H0"
    detach

    fresh "$base"; H0=$(hashp "${LOOP}p2")
    drv old "${LOOP}p3" "${LOOP}p2" --throttle --kill-at 0.3
    chk "$cfg R: the premount case reproduced too (old method killed, rc $RC)" [ "$RC" != 0 ]
    rm -f "$SCR/param.conf"
    premount ROOT_A a
    eqv "$cfg R: cmd_init_premount with the duplicate: rc 0" "$PM_RC" 0
    eqv "$cfg R: cmd_init_premount: no fallback" "$PM_SERVE" 0
    eqv "$cfg R: cmd_init_premount pins ROOT=p2 (param.conf)" "$(pinned)" "ROOT='${LOOP}p2'"
    eqv "$cfg R: cmd_init_premount relabels p3 ROOT_STALE" "$(lbl "${LOOP}p3")" ROOT_STALE
    detach

    # N. the new method interrupted at each point, then the whole clone redone
    SEC=N
    for st in a b c d; do
        SEC=N
        fresh "$base"; H0=$(hashp "${LOOP}p2")
        case $st in
            a) drv clone "${LOOP}p3" "${LOOP}p2" --crash repair_after_invalidate ;;
            b) drv clone "${LOOP}p3" "${LOOP}p2" --throttle --kill-at 0.3 ;;
            c) drv clone "${LOOP}p3" "${LOOP}p2" --crash repair_before_head ;;
            d) drv clone "${LOOP}p3" "${LOOP}p2" --crash repair_after_head ;;
        esac
        chk "$cfg N$st: interrupted (rc $RC)" [ "$RC" != 0 ]
        chk "$cfg N$st: no RESULT ok" nores "RESULT ok"
        [ "$st" = b ] && noleft "$cfg N$st: no pv or partclone left after the kill"
        if [ "$st" = d ]; then
            eqv "$cfg Nd: p3 carries ROOT_B after the head" "$(lbl "${LOOP}p3")" ROOT_B
            eqv "$cfg Nd: exactly one LABEL=ROOT_A (p2)" "$(findlabel ROOT_A)" "${LOOP}p2"
        else
            eqv "$cfg N$st: p3 has no label" "$(lbl "${LOOP}p3")" ""
            eqv "$cfg N$st: p3 has no filesystem type" "$(typ "${LOOP}p3")" ""
            eqv "$cfg N$st: exactly one LABEL=ROOT_A (p2)" "$(findlabel ROOT_A)" "${LOOP}p2"
        fi
        eqv "$cfg N$st: slot_pick ROOT_A is p2 (never p3)" "$(slot_pick ROOT_A)" "${LOOP}p2"
        p3=$(slot_pick ROOT_B 2>/dev/null || true)
        if [ "$st" = d ]; then eqv "$cfg Nd: slot_pick ROOT_B is p3" "$p3" "${LOOP}p3"
        else
            if [ -z "$p3" ] || [ "$p3" = "${LOOP}p3" ]; then ok "$cfg N$st: slot_pick ROOT_B is p3 or none"
            else bad "$cfg N$st: slot_pick ROOT_B is p3 or none (got '$p3')"; fi
        fi
        eqv "$cfg N$st: slot_dev a=p2 b=p3" "$(selv)" "a=${LOOP}p2 b=${LOOP}p3"
        premount ROOT_A a
        eqv "$cfg N$st: premount boots p2 (rc 0, no fallback)" "$PM_RC/$PM_SERVE" "0/0"
        eqv "$cfg N$st: premount pins nothing (single ROOT_A)" "$(pinned)" ""
        drv clone "${LOOP}p3" "${LOOP}p2"
        eqv "$cfg N$st: redo of the whole clone completes" "$RC" 0
        finish_checks "$cfg N$st" "$H0"
        detach
    done

    # U. the copy has ROOT_B but the source's UUID
    SEC=U
    fresh "$base"; H0=$(hashp "${LOOP}p2")
    drv clone "${LOOP}p3" "${LOOP}p2"
    eqv "$cfg U: clone completes" "$RC" 0
    tune2fs -f -U "$(uuid "${LOOP}p2")" "${LOOP}p3" >/dev/null 2>&1
    eqv "$cfg U: copy has the source's UUID and label ROOT_B" "$(uuid "${LOOP}p3")/$(lbl "${LOOP}p3")" "$(uuid "${LOOP}p2")/ROOT_B"
    eqv "$cfg U: slot_pick ROOT_A is p2" "$(slot_pick ROOT_A)" "${LOOP}p2"
    eqv "$cfg U: slot_pick ROOT_B is p3" "$(slot_pick ROOT_B)" "${LOOP}p3"
    eqv "$cfg U: slot_dev a=p2 b=p3" "$(selv)" "a=${LOOP}p2 b=${LOOP}p3"
    premount ROOT_A a
    eqv "$cfg U: premount boots p2 (rc 0, no fallback, no pin)" "$PM_RC/$PM_SERVE/$(pinned)" "0/0/"
    eqv "$cfg U: source untouched (hash)" "$(hashp "${LOOP}p2")" "$H0"
    detach

    # D. the copy target holds other data before the clone
    SEC=D
    fresh "$base"; H0=$(hashp "${LOOP}p2")
    dd if=/dev/urandom of="${LOOP}p3" bs=1M 2>/dev/null || true
    drv clone "${LOOP}p3" "${LOOP}p2"
    eqv "$cfg D random: clone over random data completes" "$RC" 0
    finish_checks "$cfg D random" "$H0"
    detach

    fresh "$base"; H0=$(hashp "${LOOP}p2")
    mkfs.ext4 -q -F -L OLDFS "${LOOP}p3"
    mount "${LOOP}p3" /mnt/s3 && dd if=/dev/urandom of=/mnt/s3/junk bs=1M count=8 2>/dev/null && echo old > /mnt/s3/old.txt
    umount /mnt/s3
    eqv "$cfg D oldfs: target carries the old label OLDFS" "$(lbl "${LOOP}p3")" OLDFS
    drv clone "${LOOP}p3" "${LOOP}p2"
    eqv "$cfg D oldfs: clone over an old ext4 completes" "$RC" 0
    finish_checks "$cfg D oldfs" "$H0"
    detach

    # E. failure modes
    SEC=E
    cp --sparse=always "$small" "$SCN"; attach "$SCN"; H0=$(hashp "${LOOP}p2")
    drv clone "${LOOP}p3" "${LOOP}p2"
    chk "$cfg E small: target smaller than the stream fails (rc $RC)" [ "$RC" = 3 ]
    chk "$cfg E small: reports write-failed" hasres "RESULT fail write-failed"
    eqv "$cfg E small: p3 has no label" "$(lbl "${LOOP}p3")" ""
    eqv "$cfg E small: p3 has no filesystem type" "$(typ "${LOOP}p3")" ""
    eqv "$cfg E small: source untouched (hash)" "$(hashp "${LOOP}p2")" "$H0"
    detach

    fresh "$base"; H0=$(hashp "${LOOP}p2")
    drv clone "${LOOP}p3" "${LOOP}p2" --throttle --kill-src-at 0.05
    chk "$cfg E src: source killed early fails (rc $RC)" [ "$RC" = 3 ]
    eqv "$cfg E src: p3 has no label" "$(lbl "${LOOP}p3")" ""
    eqv "$cfg E src: p3 has no filesystem type" "$(typ "${LOOP}p3")" ""
    noleft "$cfg E src: no pv or partclone left"
    eqv "$cfg E src: source untouched (hash)" "$(hashp "${LOOP}p2")" "$H0"
    detach
}

for cfg in gpt-csum gpt-nocsum dos-csum dos-nocsum; do
    run_cfg "${cfg%-*}" "${cfg#*-}"
done

echo
for s in setup R N U D E; do echo "section $s: ${SP[$s]:-0} passed, ${SF[$s]:-0} failed"; done
echo "TOTAL: $pass passed, $failn failed; end $(date -u +%H:%M:%S)"
[ "$failn" = 0 ]

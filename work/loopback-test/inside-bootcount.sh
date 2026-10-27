#!/bin/bash
# Fault injection for the boot counter that decides when a system that boots but never confirms
# itself is handed back to the fallback. The loopback rounds drive the OTA from the outside
# (restore, trial, promote) and never reach cmd_init_premount, so this has its own harness.
#
# cmd_init_premount has a trial_reset branch: a trial boot ignores a count left on disk by an
# unrelated earlier failure streak. That branch shares a condition with the non-trial path, where
# three unconfirmed boots in a row must still hand control to the fallback. Both directions are
# asserted, because asserting only the trial path would pass on code that never falls back.
#
# Arch-independent: cmd_init_premount is blkid/mount/e2fsck logic with no arm64-specific branch,
# so this runs in a plain amd64 container.
set -Eeuo pipefail

log() { echo ">>> $*"; }

export DEBIAN_FRONTEND=noninteractive
log "Installing the packages needed in the container..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    util-linux fdisk e2fsprogs dosfstools coreutils gdisk parted procps >/dev/null

REPO=/repo
ENGINE=(bash "$REPO/deploy/ota-engine.sh")
IMG=/work/bootcount.img
RESULTS=/work/results-bootcount.txt
: > "$RESULTS"

record() { echo "$1" | tee -a "$RESULTS"; }
check() {
    local desc="$1"; shift
    if "$@" >/tmp/check.out 2>&1; then
        record "PASS: $desc"
    else
        record "FAIL: $desc -- $(tail -5 /tmp/check.out | tr '\n' '|')"
    fi
}

# --- minimal disk: FIRMWARE (vfat) + ROOT (ext4), the only two cmd_init_premount looks at.
log "Preparing a disk with FIRMWARE(vfat) + ROOT(ext4)..."
rm -f "$IMG"
truncate -s 2G "$IMG"
sfdisk "$IMG" >/dev/null << 'EOF'
label: gpt
start=2048, size=524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="FIRMWARE"
start=526336, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ROOT"
EOF

LOOP=$(losetup --find --show --partscan "$IMG")
log "Loop device: $LOOP"

cleanup() {
    set +e
    umount -lf /boot-ota /mnt/fw 2>/dev/null
    umount -lf /proc/cmdline 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# The kernel creates the partitions (under /sys/block/<loop>/) but the container runs no udev, so
# the /dev nodes are created by hand from the major:minor in sysfs (partx -a does not help: the
# partitions already exist for the kernel).
lb=$(basename "$LOOP")
for pdir in /sys/block/"$lb"/"$lb"p*; do
    [ -d "$pdir" ] || continue
    pn=$(basename "$pdir")
    IFS=: read -r maj min < "$pdir/dev"
    [ -b "/dev/$pn" ] || mknod "/dev/$pn" b "$maj" "$min"
done
[ -b "${LOOP}p1" ] || { echo "!!! ${LOOP}p1 did not appear" >&2; exit 1; }

mkfs.vfat -n FIRMWARE "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L ROOT -F "${LOOP}p2" >/dev/null
udevadm settle --timeout=10 2>/dev/null || true

mkdir -p /mnt/fw

# The counter lives on the FIRMWARE partition, which cmd_init_premount mounts itself on /boot-ota;
# here it is written and read through a separate mount, independent of the function under test.
# Every fallback case leaves /boot-ota mounted read-only (cmd_serve_fallback never returns), and
# the kernel would hand the same superblock to a later mount of the device, which would then be
# read-only too. drop_bootota clears that between cases.
drop_bootota() {
    umount /boot-ota 2>/dev/null || umount -lf /boot-ota 2>/dev/null || true
}

set_count() {
    drop_bootota
    mount "${LOOP}p1" /mnt/fw
    if [ "$1" = "none" ]; then rm -f /mnt/fw/unitotem-ota.bootcount
    else echo "$1" > /mnt/fw/unitotem-ota.bootcount; fi
    sync; umount /mnt/fw
}
get_count() {
    drop_bootota
    mount -o ro "${LOOP}p1" /mnt/fw
    cat /mnt/fw/unitotem-ota.bootcount 2>/dev/null || echo "ABSENT"
    umount /mnt/fw
}

# cmdline_get reads /proc/cmdline directly. Bind-mounting a file over /proc/cmdline exercises the
# real code instead of a modified copy (possible because the container is privileged).
set_cmdline() {
    echo "$1" > /tmp/fake-cmdline
    umount /proc/cmdline 2>/dev/null || true
    mount --bind /tmp/fake-cmdline /proc/cmdline
}

# cmd_serve_fallback never returns (it listens with dropbear): the log line it prints before
# blocking is observed, with a timeout. It is the same line seen on serial in production.
# The timeout firing is the EXPECTED outcome in fallback cases, so it is collected (`|| rc=$?`)
# instead of letting set -e abort the harness.
run_init_premount() {
    drop_bootota
    local rc=0
    timeout 45 "${ENGINE[@]}" init-premount > /tmp/premount.out 2>&1 || rc=$?
    echo "exit=$rc" >> /tmp/premount.out
}

# ---------------------------------------------------------------------------
log "=== 4a: NON-trial boot, counter already at 3 -> must fall back ==="
# The case a silent regression would break first.
set_count 3
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
run_init_premount
cat /tmp/premount.out
check "4a: fallback triggered by the three unconfirmed boots" \
    grep -q 'three consecutive boots without confirmation' /tmp/premount.out

# ---------------------------------------------------------------------------
log "=== 4b: trial boot with an already high counter -> must still boot ==="
# A trial must not be judged by an earlier, unrelated failure streak.
set_count 7
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet unitotem.ota.bootcount=1"
run_init_premount
cat /tmp/premount.out
check "4b: no fallback on a trial boot" \
    bash -c "! grep -q 'three consecutive boots' /tmp/premount.out"
check "4b: init-premount returns 0 (mountroot continues)" \
    grep -q 'exit=0' /tmp/premount.out
c=$(get_count); record "4b: counter after the trial = $c (expected 1, not 8)"
check "4b: the trial resets the counter instead of inheriting it" test "$c" = "1"

# ---------------------------------------------------------------------------
log "=== 4c: NON-trial boot below the threshold -> continues and increments ==="
set_count 2
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
run_init_premount
check "4c: no fallback at count 2" \
    bash -c "! grep -q 'three consecutive boots' /tmp/premount.out"
check "4c: init-premount returns 0" grep -q 'exit=0' /tmp/premount.out
c=$(get_count); record "4c: counter after boot = $c (expected 3)"
check "4c: counter incremented, not reset" test "$c" = "3"

# ---------------------------------------------------------------------------
log "=== 4d: very first boot, no counter -> continues and creates it ==="
set_count none
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
run_init_premount
check "4d: init-premount returns 0 without a pre-existing counter" \
    grep -q 'exit=0' /tmp/premount.out

# 4e runs before get_count: get_count calls drop_bootota, which would unmount /boot-ota and make
# this check vacuous. A /boot-ota left mounted makes the real system's boot-firmware.mount fail
# with EBUSY on every boot and the machine ends up in emergency mode.
log "=== 4e: /boot-ota must not stay mounted after a normal boot ==="
check "4e: /boot-ota unmounted when init-premount returns" \
    bash -c '! mountpoint -q /boot-ota'

c=$(get_count); record "4d: counter created = $c (expected 1)"
check "4d: counter created at 1" test "$c" = "1"

# ---------------------------------------------------------------------------
log "=== 4f: ROOT missing -> fallback ==="
# The other trigger, independent of the counter.
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
e2label "${LOOP}p2" NOTROOT
udevadm settle --timeout=10 2>/dev/null || true
run_init_premount
check "4f: fallback when the ROOT partition does not exist" \
    grep -q 'partition ROOT not found' /tmp/premount.out
e2label "${LOOP}p2" ROOT

# A/B: the slot to validate is the one named in root=, not a fixed "ROOT".
log "=== 4g: A/B layout, root=LABEL=ROOT_B ==="
e2label "${LOOP}p2" ROOT_B
udevadm settle --timeout=10 2>/dev/null || true
rm -f /boot-ota/unitotem-ota.bootcount 2>/dev/null || true
set_cmdline "console=tty1 root=LABEL=ROOT_B ro quiet unitotem.slot=b"
run_init_premount
check "4g: no fallback if the slot B named in root= exists" \
    bash -c '! grep -q "not found\|filesystem errors" /tmp/premount.out'
set_cmdline "console=tty1 root=LABEL=ROOT_A ro quiet unitotem.slot=a"
run_init_premount
check "4g: fallback if the slot A named in root= does not exist (even though ROOT_B does)" \
    grep -q 'partition ROOT_A not found' /tmp/premount.out
e2label "${LOOP}p2" ROOT

# --- A/B: no counter, no write to the FAT -------------------------------------
log "=== 4h: A/B layout -> the counter is neither used nor touched ==="
set_count 5
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet unitotem.slot=a"
run_init_premount
check "4h: A/B does not fall back on a high counter" bash -c '! grep -q "three consecutive" /tmp/premount.out'
check "4h: A/B: init-premount returns 0" grep -q 'exit=0' /tmp/premount.out
c=$(get_count); record "4h: counter after the A/B boot = $c (expected 5, untouched)"
check "4h: A/B: the FAT was not written (counter unchanged)" bash -c "[ '$c' = 5 ]"
check "4h: A/B: /boot-ota unmounted" bash -c '! mountpoint -q /boot-ota'

# --- the ROOT check must not write ---------------------------------------------
log "=== 4i: the ROOT check is read-only ==="
set_count none
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
before=$(dumpe2fs -h "${LOOP}p2" 2>/dev/null | grep -E 'Last checked|Last write time|Filesystem state' | md5sum)
run_init_premount
after=$(dumpe2fs -h "${LOOP}p2" 2>/dev/null | grep -E 'Last checked|Last write time|Filesystem state' | md5sum)
check "4i: the ROOT superblock did not change after init-premount (e2fsck -fy would rewrite it)" bash -c "[ '$before' = '$after' ]"

# --- fallback watchdog ------------------------------------------------------
log "=== 4j: the fallback with no host reboots by itself ==="
rm -f /tmp/reboot-called
cat > /usr/local/bin/reboot << 'EOS'
#!/bin/sh
echo "$@" > /tmp/reboot-called
EOS
chmod +x /usr/local/bin/reboot
drop_bootota
timeout 25 "${ENGINE[@]}" serve-fallback --reason "test" --idle-timeout 10 > /tmp/idle.out 2>&1 || true
# In this container dropbear does not exist, so serve-fallback returns at once; the watchdog it started in the
# background is what is being tested, and it needs its 10 s.
for _ in $(seq 1 20); do [ -f /tmp/reboot-called ] && break; sleep 1; done
check "4j: no host connected -> reboot requested after the wait" test -f /tmp/reboot-called
rm -f /tmp/reboot-called /usr/local/bin/reboot

echo
log "=== RESULTS ==="
cat "$RESULTS"
if grep -q '^FAIL:' "$RESULTS"; then
    echo "!!! Some checks failed" >&2
    exit 1
fi
log "All boot-counter checks passed."

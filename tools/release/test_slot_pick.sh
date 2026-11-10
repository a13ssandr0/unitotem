#!/bin/bash
# Tests of the slot lookup with duplicate labels (slot_pick, heal_dup_label, pin_root_dev and their use in
# cmd_init_premount and ab_failover, deploy/ota-engine.sh). Fixtures only: the sysfs block tree, the blkid database,
# /proc/mounts and the initramfs param.conf are tmp files (OTA_SYS_BLOCK, OTA_PROC_MOUNTS, OTA_CONF_PARAM). blkid,
# e2label, mount, umount, mountpoint, sync, sleep, udevadm, modprobe, the log functions, bootcount_gate,
# cmd_serve_fallback, check_flag_file and check_root_readonly are stubs.
#   bash tools/release/test_slot_pick.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENGINE="$HERE/../../deploy/ota-engine.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/unitotem-slot-pick-test.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# shellcheck disable=SC1090
. "$ENGINE"
set +e +u
trap - ERR   # the engine's ERR trap calls fail(), which exits; the tests check return codes themselves

# ---- stubs: defined after the engine is sourced ----
LOGS=(); WARNS=(); E2_CALLS=(); SERVE_CALLS=(); CHECK_ARGS=(); E2_FAIL=""; CHECK_FAIL=0
BLKID_DB=""; TEST_CMDLINE=""; BOOTCOUNT_RECOVERY=0
mount()             { return 0; }
umount()            { return 0; }
mountpoint()        { return 0; }
sync()              { :; }
sleep()             { :; }
udevadm()           { return 0; }
modprobe()          { return 0; }
kmsg()              { :; }
log()               { LOGS+=("$*"); }
warn()              { WARNS+=("$*"); }
check_flag_file()   { return 1; }
bootcount_gate()    { BOOTCOUNT_RECOVERY=0; }
cmd_serve_fallback() { SERVE_CALLS+=("$*"); return 0; }
check_root_readonly() { CHECK_ARGS+=("$1"); [ "$CHECK_FAIL" = 0 ]; }
e2label()           { E2_CALLS+=("$*"); [ "$1" != "$E2_FAIL" ]; }
# blkid -t LABEL=X -o device: the matching devices of $BLKID_DB, in file order; rc 2 when none (as blkid does).
blkid() {
    local out
    if [ "${1:-}" = -t ] && [ "${2:0:6}" = LABEL= ] && [ "${3:-}" = -o ] && [ "${4:-}" = device ]; then
        out=$(awk -v l="${2#LABEL=}" '$2 == l { print $1 }' "$BLKID_DB" 2>/dev/null)
        [ -n "$out" ] || return 2
        printf '%s\n' "$out"
        return 0
    fi
    return 2
}
# Same contract as the engine's cmdline_get, read from $TEST_CMDLINE.
cmdline_get() {
    local tok; local -a toks=()
    read -ra toks < "$TEST_CMDLINE" || true
    for tok in "${toks[@]}"; do
        case "$tok" in "$1="*) printf '%s\n' "${tok#*=}"; return 0 ;; esac
    done
    return 1
}

PASS=0; FAIL=0
check() {   # check NAME ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "PASS: $1"
    else FAIL=$((FAIL + 1)); echo "FAIL: $1 (got '$2', expected '$3')"; fi
}
ok() {      # ok NAME COMMAND...: counts PASS or FAIL
    local name="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); echo "PASS: $name"
    else FAIL=$((FAIL + 1)); echo "FAIL: $name"; fi
}

# ---- fixtures: one tree per case ----
SYS=""; DEVS=""
fx() {   # fx NAME: fresh sysfs tree, blkid database, /proc/mounts and param.conf; call logs reset
    local d="$TMP/$1"
    SYS="$d/sys"; DEVS="$d/devices"
    mkdir -p "$SYS" "$DEVS"
    BLKID_DB="$d/blkid"; : > "$BLKID_DB"
    OTA_SYS_BLOCK="$SYS"
    OTA_PROC_MOUNTS="$d/mounts"; : > "$OTA_PROC_MOUNTS"
    OTA_CONF_PARAM="$d/param.conf"
    OTA_BOOTFS_MNT="$d/boot"; mkdir -p "$OTA_BOOTFS_MNT"
    TEST_CMDLINE="$d/cmdline"
    LOGS=(); WARNS=(); E2_CALLS=(); SERVE_CALLS=(); CHECK_ARGS=(); E2_FAIL=""; CHECK_FAIL=0
}
disk() {        # disk NAME: a whole disk
    mkdir -p "$DEVS/$1"; ln -sfn "$DEVS/$1" "$SYS/$1"
}
part() {        # part DISK NAME NUM: partition NAME whose sysfs entry sits under DISK (symlink target is the truth)
    mkdir -p "$DEVS/$1/$2"; printf '%s\n' "$3" > "$DEVS/$1/$2/partition"
    ln -sfn "$DEVS/$1/$2" "$SYS/$2"
}
db() {          # db DEV LABEL [UUID]: one blkid row
    printf '/dev/%s %s %s\n' "${1#/dev/}" "$2" "${3:-}" >> "$BLKID_DB"
}
cmdline() { printf '%s\n' "$1" > "$TEST_CMDLINE"; }

# ---- 1. slot_pick: match counts ----
fx single
disk sda; part sda sda2 2; db /dev/sda2 ROOT_A
out=$(slot_pick ROOT_A); rc=$?
check "single match: device" "$out" "/dev/sda2"
check "single match: rc" "$rc" "0"

fx none
disk sda; part sda sda2 2; db /dev/sda2 ROOT_B
out=$(slot_pick ROOT_A); rc=$?
check "no match: prints nothing" "$out" ""
check "no match: rc 1" "$rc" "1"

# ---- 2. two matches on one disk: ROOT_A lowest, ROOT_B highest ----
fx dup_a
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda3 ROOT_A 1111; db /dev/sda2 ROOT_A 1111
check "two ROOT_A on sda (p2, p3): lowest partition" "$(slot_pick ROOT_A)" "/dev/sda2"

fx dup_b
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda2 ROOT_B; db /dev/sda3 ROOT_B
check "two ROOT_B on sda (p2, p3): highest partition" "$(slot_pick ROOT_B)" "/dev/sda3"

fx dup_other
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda3 DATA; db /dev/sda2 DATA
check "other label on one disk: first sorted" "$(slot_pick DATA)" "/dev/sda2"

# ---- 3. matches on several disks: first sorted match, no label rule ----
fx multi_disk
disk sda; disk sdb; part sda sda2 2; part sda sda3 3; part sdb sdb9 9
db /dev/sdb9 ROOT_B; db /dev/sda3 ROOT_B; db /dev/sda2 ROOT_B
check "ROOT_B on sda (p2, p3) and sdb (p9): first sorted, not the label rule" "$(slot_pick ROOT_B)" "/dev/sda2"
fx multi_disk_two
disk sda; disk sdb; part sda sda2 2; part sdb sdb2 2
db /dev/sdb2 ROOT_A; db /dev/sda2 ROOT_A
check "ROOT_A on sda2 and sdb2: first sorted" "$(slot_pick ROOT_A)" "/dev/sda2"

# ---- 4. MBR and NVMe names: the disk comes from the sysfs symlink target ----
fx mbr
disk mmcblk0; part mmcblk0 mmcblk0p3 3; part mmcblk0 mmcblk0p2 2
db /dev/mmcblk0p3 ROOT_B; db /dev/mmcblk0p2 ROOT_A
check "mmcblk0p2/p3 ROOT_A: p2" "$(slot_pick ROOT_A)" "/dev/mmcblk0p2"
check "mmcblk0p2/p3 ROOT_B: p3" "$(slot_pick ROOT_B)" "/dev/mmcblk0p3"

fx nvme
disk nvme0n1; part nvme0n1 nvme0n1p2 2; part nvme0n1 nvme0n1p3 3
db /dev/nvme0n1p3 ROOT_A; db /dev/nvme0n1p2 ROOT_A
check "nvme0n1p2/p3 ROOT_A: p2" "$(slot_pick ROOT_A)" "/dev/nvme0n1p2"
fx nvme_b
disk nvme0n1; part nvme0n1 nvme0n1p2 2; part nvme0n1 nvme0n1p3 3
db /dev/nvme0n1p2 ROOT_B; db /dev/nvme0n1p3 ROOT_B
check "nvme0n1p2/p3 ROOT_B: p3" "$(slot_pick ROOT_B)" "/dev/nvme0n1p3"

# The disk is the symlink target: sdb2 sits under disk sda, sda3 under disk sdb (names say the opposite).
fx symlink_disk
disk sda; part sda sdb2 2; part sda sda3 3
db /dev/sda3 ROOT_A; db /dev/sdb2 ROOT_A
check "disk from the symlink target, not the name: sdb2 (p2) on disk sda wins over sda3" "$(slot_pick ROOT_A)" "/dev/sdb2"

# The partition number is the sysfs partition file, not the name.
fx sysfs_number
disk sda; part sda sdz 2; part sda sdy 3
db /dev/sdy ROOT_A; db /dev/sdz ROOT_A
check "partition number from sysfs (sdz is p2, sdy is p3)" "$(slot_pick ROOT_A)" "/dev/sdz"

# ---- 5. duplicate UUID does not matter ----
fx same_uuid
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda2 ROOT_A 4444-5555; db /dev/sda3 ROOT_A 4444-5555
check "same UUID on both: still the lowest partition" "$(slot_pick ROOT_A)" "/dev/sda2"

# ---- 6. heal_dup_label ----
fx heal
disk sda; disk sdb; part sda sda2 2; part sda sda3 3; part sdb sdb2 2
db /dev/sda2 ROOT_A 1111; db /dev/sda3 ROOT_A 1111; db /dev/sdb2 ROOT_A 2222
heal_dup_label ROOT_A /dev/sda2
check "heal: one relabel call, on the other device of the same disk" "${E2_CALLS[*]:-}" "/dev/sda3 ROOT_STALE"
check "heal: one warning naming the device" "$(printf '%s\n' "${WARNS[@]:-}" | grep -c '/dev/sda3')" "1"
ok "heal: the picked device and the other disk are not touched" eval '[ "${#E2_CALLS[@]}" = 1 ] && [[ "${E2_CALLS[0]}" != /dev/sda2* ]] && [[ "${E2_CALLS[0]}" != /dev/sdb2* ]]'

fx heal_mounted
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda2 ROOT_A; db /dev/sda3 ROOT_A
printf '/dev/sda3 /mnt/x ext4 rw 0 0\n' > "$OTA_PROC_MOUNTS"
heal_dup_label ROOT_A /dev/sda2
check "heal: a mounted duplicate is not relabelled" "${#E2_CALLS[@]}" "0"
check "heal: a mounted duplicate is reported" "$(printf '%s\n' "${WARNS[@]:-}" | grep -c 'mounted')" "1"

fx heal_fail
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda2 ROOT_A; db /dev/sda3 ROOT_A
E2_FAIL=/dev/sda3
heal_dup_label ROOT_A /dev/sda2
check "heal: a failed relabel is reported" "$(printf '%s\n' "${WARNS[@]:-}" | grep -c 'relabel to ROOT_STALE failed')" "1"

# ---- 7. pin_root_dev: ROOT= only through the validated, quoted line ----
fx pin
pin_root_dev /dev/sda2
check "pin: ROOT line appended, quoted" "$(cat "$OTA_CONF_PARAM")" "ROOT='/dev/sda2'"
pin_root_dev "/dev/x;reboot"; rc=$?
check "pin: a value with shell characters is refused" "$rc" "1"
pin_root_dev "sda2"; rc=$?
check "pin: a value that is not a /dev path is refused" "$rc" "1"
check "pin: refused values are not written" "$(cat "$OTA_CONF_PARAM")" "ROOT='/dev/sda2'"

# ---- 8. cmd_init_premount end to end ----
fx premount_dup_a
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda2 ROOT_A 1111; db /dev/sda3 ROOT_A 1111
cmdline "root=LABEL=ROOT_A ro quiet unitotem.slot=a"
printf 'FOO=1\n' > "$OTA_CONF_PARAM"
cmd_init_premount; rc=$?
check "premount dup ROOT_A: rc 0" "$rc" "0"
check "premount dup ROOT_A: root checked is the picked device" "${CHECK_ARGS[0]:-}" "/dev/sda2"
check "premount dup ROOT_A: stale duplicate relabelled" "${E2_CALLS[*]:-}" "/dev/sda3 ROOT_STALE"
check "premount dup ROOT_A: param.conf keeps its content and gets ROOT" "$(cat "$OTA_CONF_PARAM")" "$(printf 'FOO=1\nROOT=%s' "'/dev/sda2'")"
ok "premount dup ROOT_A: no fallback" [ "${#SERVE_CALLS[@]}" = 0 ]

fx premount_dup_b
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda2 ROOT_B; db /dev/sda3 ROOT_B
cmdline "root=LABEL=ROOT_B ro quiet unitotem.slot=b"
cmd_init_premount; rc=$?
check "premount dup ROOT_B: rc 0" "$rc" "0"
check "premount dup ROOT_B: picks p3 and pins it" "$(cat "$OTA_CONF_PARAM")" "ROOT='/dev/sda3'"
check "premount dup ROOT_B: stale p2 relabelled" "${E2_CALLS[*]:-}" "/dev/sda2 ROOT_STALE"

fx premount_single
disk sda; part sda sda2 2
db /dev/sda2 ROOT_A
cmdline "root=LABEL=ROOT_A ro quiet unitotem.slot=a"
cmd_init_premount; rc=$?
check "premount single: rc 0" "$rc" "0"
ok "premount single: param.conf not created" [ ! -e "$OTA_CONF_PARAM" ]
ok "premount single: nothing relabelled" [ "${#E2_CALLS[@]}" = 0 ]
check "premount single: root checked" "${CHECK_ARGS[0]:-}" "/dev/sda2"

fx premount_cross_disk
disk sda; disk sdb; part sda sda2 2; part sdb sdb2 2
db /dev/sdb2 ROOT_A; db /dev/sda2 ROOT_A
cmdline "root=LABEL=ROOT_A ro quiet unitotem.slot=a"
cmd_init_premount
ok "premount cross-disk dup: nothing relabelled on the other disk" [ "${#E2_CALLS[@]}" = 0 ]
check "premount cross-disk dup: first sorted device pinned" "$(cat "$OTA_CONF_PARAM")" "ROOT='/dev/sda2'"

fx premount_missing
cmdline "root=LABEL=ROOT_A ro quiet unitotem.slot=a"
cmd_init_premount
check "premount missing root: fallback with the partition reason" "${SERVE_CALLS[0]:-}" "--reason partition ROOT_A not found --kind recovery --idle-timeout 21600"
ok "premount missing root: no param.conf" [ ! -e "$OTA_CONF_PARAM" ]

# ---- 9. ab_failover takes the other slot through slot_pick ----
fx failover
disk sda; part sda sda2 2; part sda sda3 3
db /dev/sda2 ROOT_A; db /dev/sda3 ROOT_A
cmdline "root=LABEL=ROOT_B ro quiet unitotem.slot=b"
CHECK_FAIL=1
ab_failover; rc=$?
check "ab_failover: the other slot is checked by its picked device" "${CHECK_ARGS[0]:-}" "/dev/sda2"
check "ab_failover: returns 1 when that check fails (no writes made)" "$rc" "1"

echo
echo "slot pick tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

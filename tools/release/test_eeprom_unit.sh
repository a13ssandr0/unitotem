#!/bin/bash
# Test of unitotem/files/unitotem-eeprom-update and its systemd drop-in with fake rpi-eeprom-update, mount, mountpoint, vcgencmd,
# timedatectl, logger and sleep on PATH. Nothing on the host is touched: the boot directory, the mount state and the log live in a
# temporary directory.
#   tools/release/test_eeprom_unit.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$DIR/unitotem/files/unitotem-eeprom-update"
D="$DIR/unitotem/files/rpi-eeprom-update.service.d-unitotem.conf"
ok=0 fail=0
check() { if "${@:2}" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin" "$T/boot"
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
mk logger 'shift 3; printf "%s\n" "$*" >> "$T/log"'
mk sleep 'exit 0'
mk sync 'exit 0'
# mount state: file mnt holds ro or rw; mountpoint succeeds unless nomount exists; mount fails when failmount exists
mk mountpoint '[ ! -e "$T/nomount" ]'
mk mount '[ -e "$T/failmount" ] && exit 32; echo "$2" >> "$T/mounts"; exit 0'
mk vcgencmd 'echo "throttled=$(cat "$T/throttled")"'
mk timedatectl 'cat "$T/ntp"'
mk rpi-eeprom-update 'echo "tool $*"; exit "$(cat "$T/rc")"'
export T
export PATH="$T/bin:$PATH" UNITOTEM_EEPROM_BOOT="$T/boot" UNITOTEM_EEPROM_TOOL="$T/bin/rpi-eeprom-update" UNITOTEM_EEPROM_CLOCK_WAIT=4
reset() { rm -f "$T/log" "$T/mounts" "$T/nomount" "$T/failmount" "$T/boot/pieeprom.upd" "$T/boot/recovery.bin"; echo 0x0 > "$T/throttled"; echo yes > "$T/ntp"; echo 0 > "$T/rc"; }
rc_of() { "$H" "$@" >/dev/null 2>&1; echo $?; }

# unit directives
check "unit: after multi-user, network-online and time-sync" grep -qx 'After=multi-user.target network-online.target time-sync.target' "$D"
check "unit: wants network-online, no Requires" bash -c "grep -qx 'Wants=network-online.target' '$D' && ! grep -q '^Requires=' '$D'"
check "unit: bounded start" grep -qE '^TimeoutStartSec=[0-9]+$' "$D"
check "unit: skipped without an EEPROM bootloader" grep -q '^ConditionPathExists=/proc/device-tree/chosen/bootloader/build-timestamp$' "$D"
check "unit: ExecStart reset then helper run" bash -c "grep -n '^ExecStart=' '$D' | head -1 | grep -q ':ExecStart=\$' && grep -qx 'ExecStart=/usr/lib/unitotem/eeprom-update run' '$D'"
check "unit: ExecCondition check and ExecStopPost ro" bash -c "grep -qx 'ExecCondition=/usr/lib/unitotem/eeprom-update check' '$D' && grep -qx 'ExecStopPost=/usr/lib/unitotem/eeprom-update ro' '$D'"
check "unit: no stage2 hook for amd64" bash -c "grep -B1 -A3 'eeprom-update' '$DIR/unitotem/stage2-configure.sh' | grep -q 'ARCH\" = \"arm64\"'"

# check: proceeds and leaves the FAT rw
reset; check "check: clean state proceeds" test "$(rc_of check)" = 0
check "check: FAT remounted rw" grep -qx remount,rw "$T/mounts"
reset; echo 0x50005 > "$T/throttled"; check "check: under-voltage now skips (1)" test "$(rc_of check)" = 1
check "check: skip is logged" grep -q 'skipped' "$T/log"
reset; echo 0x50000 > "$T/throttled"; check "check: history-only bits (16+) do not skip" test "$(rc_of check)" = 0
reset; echo 0x4 > "$T/throttled"; check "check: throttled now skips" test "$(rc_of check)" = 1
reset; echo 0x8 > "$T/throttled"; check "check: soft temperature limit skips" test "$(rc_of check)" = 1
reset; echo garbage > "$T/throttled"; check "check: unreadable power state skips" test "$(rc_of check)" = 1
reset; echo no > "$T/ntp"; check "check: unsynchronized clock skips after the bounded wait" test "$(rc_of check)" = 1
reset; touch "$T/failmount"; check "check: failed remount skips" test "$(rc_of check)" = 1
reset; chmod 555 "$T/boot"; touch "$T/nomount"; if [ -w "$T/boot" ]; then echo "SKIP: running as root, no unwritable directory"; else check "check: unwritable FAT skips" test "$(rc_of check)" = 1; fi; chmod 755 "$T/boot"

# run: exit mapping
reset; check "run: exit 0 is success" test "$(rc_of run)" = 0
reset; echo 3 > "$T/rc"; check "run: frozen (3) is success" test "$(rc_of run)" = 0
reset; echo 2 > "$T/rc"; check "run: exit 2 is returned" test "$(rc_of run)" = 2
check "run: failure logged at warning (journal keeps it)" grep -q 'failed (exit 2)' "$T/log"
reset; touch "$T/boot/pieeprom.upd"; check "run: staged update is logged" bash -c "'$H' run >/dev/null; grep -q 'staged' '$T/log'"
reset; "$H" run >/dev/null; check "run: nothing staged, nothing logged" test ! -e "$T/log"

# ro: restored after a failure and idempotent
reset; echo 2 > "$T/rc"; "$H" check; "$H" run >/dev/null; "$H" ro
check "ro: remount ro issued after a failed run" grep -qx remount,ro "$T/mounts"
reset; touch "$T/nomount"; check "ro: no mount point is a no-op" test "$(rc_of ro)" = 0
reset; check "usage error" test "$(rc_of bogus)" = 64
echo "== $ok passed, $fail failed"
[ "$fail" = 0 ]

#!/bin/bash
# Test of unitotem/files/unitotem-acpi-storm-guard against a fake /sys/firmware/acpi/interrupts directory: a storming event is masked and
# logged, quiet events and the other counters are left alone, bad input is refused, every storm is recorded in the state file (once per
# boot, rate kept as the maximum). Nothing on the host is touched: the state file lives in the temporary directory.
#   tools/release/test_acpi_storm_guard.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$DIR/unitotem/files/unitotem-acpi-storm-guard"
ok=0 fail=0
check() { if "${@:2}" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"
# logger writes its message to a file instead of the journal
printf '#!/bin/sh\nshift 4\nprintf "%%s\\n" "$*" >> "%s/log"\n' "$T" > "$T/bin/logger"; chmod +x "$T/bin/logger"
export PATH="$T/bin:$PATH"
# the state file is always inside the temporary directory, never /var/lib
S="$T/state/acpi-storms"
export UNITOTEM_ACPI_STATE="$S"
B1=11111111-1111-4111-8111-111111111111
B2=22222222-2222-4222-8222-222222222222
B3=33333333-3333-4333-8333-333333333333
B4=44444444-4444-4444-8444-444444444444
B5=55555555-5555-4555-8555-555555555555
B6=66666666-6666-4666-8666-666666666666

# the counters of the fake event files grow in the background, the way the kernel's do; masking = the line "mask" is written to the file
mk() { # mk NAME RATE: file with count and a ticker that adds RATE per second
    printf '1000  EN enabled unmasked\n' > "$T/i/$1"
    ( while sleep 0.1; do read -r c rest < "$T/i/$1"; [ "$(cat "$T/i/$1.masked" 2>/dev/null)" = 1 ] && continue; case $c in *[!0-9]*) continue ;; esac; printf '%s %s\n' $((c + $2 / 10)) "$rest" > "$T/i/$1.tmp" && mv "$T/i/$1.tmp" "$T/i/$1"; done ) &
    echo $! >> "$T/pids"
}
reset() { rm -rf "$T/i" "$T/log"; mkdir -p "$T/i"; : > "$T/pids"; }
stop() { while read -r p; do kill "$p" 2>/dev/null; done < "$T/pids"; wait 2>/dev/null; }
# watch NAME...: sets the "masked" marker of each event once the script has written "mask" to it
watch() { ( while sleep 0.05; do for g in "$@"; do grep -q '^mask' "$T/i/$g" 2>/dev/null && echo 1 > "$T/i/$g.masked"; done; done ) & echo $! >> "$T/pids"; }
# run BOOT [STATE]: one run of the guard with the given boot id and state file
run() { UNITOTEM_ACPI_DIR="$T/i" UNITOTEM_ACPI_SAMPLE=1 UNITOTEM_ACPI_STORM_LIMIT=2000 UNITOTEM_BOOT_ID="$1" UNITOTEM_ACPI_STATE="${2:-$S}" sh "$SCRIPT"; }
# storm BOOT NAME:RATE...: one run with the given fake events; the result code is left in rc
storm() {
    local b=$1 p n r names=""
    shift
    reset
    for p in "$@"; do n=${p%%:*}; r=${p#*:}; mk "$n" "$r"; names="$names $n"; done
    watch $names
    run "$b" "${ST:-$S}"; rc=$?
    sleep 0.3; stop
}

reset; mk gpe03 10000; mk gpe66 5; mk gpe0A 100
printf '5000000  \n' > "$T/i/sci"; printf '5000000  \n' > "$T/i/gpe_all"
# "mask" written by the script goes to the file: the ticker watches a marker instead, set by this wrapper around the file
( while sleep 0.05; do grep -q '^mask' "$T/i/gpe03" 2>/dev/null && echo 1 > "$T/i/gpe03.masked"; done ) & echo $! >> "$T/pids"
run "$B1"; rc=$?
sleep 0.3
check "the guard exits 0" [ "$rc" = 0 ]
check "the storming event is written 'mask'" grep -q '^mask' "$T/i/gpe03"
check "it is logged with its rate" grep -qE 'masked ACPI event gpe03: [0-9]+ events per second' "$T/log"
check "a quiet event is left alone" bash -c "! grep -q '^mask' '$T/i/gpe66' && ! grep -q '^mask' '$T/i/gpe0A'"
check "sci and gpe_all are not events: left alone" bash -c "! grep -q '^mask' '$T/i/sci' && ! grep -q '^mask' '$T/i/gpe_all'"
check "exactly one event masked" [ "$(grep -c masked "$T/log")" = 1 ]
stop

reset; mk gpe03 5; mk gpe66 50
run "$B1"; sleep 0.2
check "a machine with no storm: nothing is masked or logged" bash -c "! grep -q '^mask' '$T/i/gpe03' && ! grep -q '^mask' '$T/i/gpe66' && [ ! -s '$T/log' ]"
stop

reset; mk gpe03 3000; mk gpe05 20000
( while sleep 0.05; do for g in gpe03 gpe05; do grep -q '^mask' "$T/i/$g" 2>/dev/null && echo 1 > "$T/i/$g.masked"; done; done ) & echo $! >> "$T/pids"
run "$B1"; sleep 0.3
check "two storming events are both masked" bash -c "grep -q '^mask' '$T/i/gpe03' && grep -q '^mask' '$T/i/gpe05' && [ \$(grep -c masked '$T/log') = 2 ]"
stop

check "a missing directory is not an error" env UNITOTEM_ACPI_DIR="$T/nonexistent" sh "$SCRIPT"
check "a bad limit is refused" bash -c "! UNITOTEM_ACPI_DIR='$T' UNITOTEM_ACPI_STORM_LIMIT='1;rm -rf /' sh '$SCRIPT'"
check "a zero sample is refused" bash -c "! UNITOTEM_ACPI_DIR='$T' UNITOTEM_ACPI_SAMPLE=0 sh '$SCRIPT'"
check "the script is POSIX sh (dash parses it)" bash -c "command -v dash >/dev/null && dash -n '$SCRIPT' || sh -n '$SCRIPT'"

# state file: a quiet machine writes nothing, not even the directory
reset; mk gpe03 5; mk gpe66 50
run "$B1" "$T/quiet/acpi-storms"; rc=$?; sleep 0.2; stop
check "a quiet machine: exit 0, no state file and no directory created" bash -c "[ '$rc' = 0 ] && [ ! -e '$T/quiet' ]"

# state file: first record, then the same boot, a new boot and a lower rate in a new boot
rm -f -- "$S"
t0=$(date +%s)
storm "$B1" gpe03:10000
check "first record: one line" [ "$(wc -l < "$S")" = 1 ]
check "first record: fields exact (name first last rate boots boot_id masked)" bash -c "grep -Eq '^gpe03 [0-9]+ [0-9]+ [0-9]+ 1 $B1 1\$' '$S'"
check "first record: first and last are epoch seconds of this run, rate above the limit" awk -v t0="$t0" -v b="$B1" '$1=="gpe03" && $2>=t0 && $3>=$2 && $4>2000 && $5==1 && $6==b && $7==1 {ok=1} END {exit !ok}' "$S"
F1=$(awk '$1=="gpe03" {print $2}' "$S"); L1=$(awk '$1=="gpe03" {print $3}' "$S"); R1=$(awk '$1=="gpe03" {print $4}' "$S")

sleep 1
storm "$B1" gpe03:3000
check "same boot: exit 0" [ "$rc" = 0 ]
check "same boot: no double count (boots stays 1, boot id kept)" awk -v b="$B1" -v f="$F1" -v l="$L1" -v r="$R1" '$1=="gpe03" && $2==f && $3>l && $4==r && $5==1 && $6==b && $7==1 {ok=1} END {exit !ok}' "$S"
check "same boot: one line only" [ "$(wc -l < "$S")" = 1 ]
L2=$(awk '$1=="gpe03" {print $3}' "$S")

sleep 1
storm "$B2" gpe03:20000
check "new boot: boots 2, boot id of the new boot, last updated, first kept" awk -v b="$B2" -v f="$F1" -v l="$L2" '$1=="gpe03" && $2==f && $3>l && $5==2 && $6==b && $7==1 {ok=1} END {exit !ok}' "$S"
check "new boot: higher rate kept" awk -v r="$R1" '$1=="gpe03" && $4>r {ok=1} END {exit !ok}' "$S"
R3=$(awk '$1=="gpe03" {print $4}' "$S")

storm "$B3" gpe03:3000
check "new boot, lower rate: max not lowered, boots 3" awk -v r="$R3" -v b="$B3" '$1=="gpe03" && $4==r && $5==3 && $6==b {ok=1} END {exit !ok}' "$S"

# state file: two events in two lines, lower-case kernel name normalised
ST= ; rm -f -- "$S"
storm "$B4" gpe03:10000 gpe0a:20000
check "two events: two lines" [ "$(wc -l < "$S")" = 2 ]
check "two events: lower-case gpe0a recorded as gpe0A" bash -c "grep -q '^gpe0A ' '$S' && ! grep -q '^gpe0a ' '$S'"
check "two events: both lines valid and masked" [ "$(awk -v b="$B4" 'NF==7 && $5==1 && $6==b && $7==1' "$S" | wc -l)" = 2 ]

# state file: corrupt content is ignored (replaced by a valid file), a valid line of another event is kept
printf 'garbage\ngpe0a 1 2 3 1 %s 1\ngpe03 1 2 3 x %s 1\ngpe03 1 2 3 4 %s 1 extra\ngpe66 100 200 5 7 %s 0\n' "$B1" "$B1" "$B1" "$B1" > "$S"
storm "$B5" gpe05:10000
check "corrupt state: exit 0 and the storm is masked" bash -c "[ '$rc' = 0 ] && grep -q '^mask' '$T/i/gpe05'"
check "corrupt state: garbage gone, new record written, valid line of gpe66 kept" bash -c "! grep -q garbage '$S' && grep -Eq '^gpe05 [0-9]+ [0-9]+ [0-9]+ 1 $B5 1\$' '$S' && grep -q '^gpe66 100 200 5 7 $B1 0\$' '$S' && [ \$(wc -l < '$S') = 2 ]"

# state file: an unwritable directory (its parent is a regular file): the masking happens, the failure is logged, exit 0
printf 'x\n' > "$T/blocker"
ST="$T/blocker/acpi-storms" storm "$B6" gpe03:10000
check "unwritable state: exit 0 and the storm is masked" bash -c "[ '$rc' = 0 ] && grep -q '^mask' '$T/i/gpe03'"
check "unwritable state: the failure is logged" grep -q 'cannot record ACPI storms' "$T/log"
check "unwritable state: nothing written in place of the blocker file" [ -f "$T/blocker" ]
ST=

echo "$ok passed, $fail failed"; [ "$fail" = 0 ]

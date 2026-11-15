#!/bin/bash
# Test of unitotem/files/unitotem-acpi-storm-guard against a fake /sys/firmware/acpi/interrupts directory: a storming event is masked and
# logged, quiet events and the other counters are left alone, bad input is refused. Nothing on the host is touched.
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

# the counters of the fake event files grow in the background, the way the kernel's do; masking = the line "mask" is written to the file
mk() { # mk NAME RATE: file with count and a ticker that adds RATE per second
    printf '1000  EN enabled unmasked\n' > "$T/i/$1"
    ( while sleep 0.1; do read -r c rest < "$T/i/$1"; [ "$(cat "$T/i/$1.masked" 2>/dev/null)" = 1 ] && continue; printf '%s %s\n' $((c + $2 / 10)) "$rest" > "$T/i/$1.tmp" && mv "$T/i/$1.tmp" "$T/i/$1"; done ) &
    echo $! >> "$T/pids"
}
reset() { rm -rf "$T/i" "$T/log"; mkdir -p "$T/i"; : > "$T/pids"; }
stop() { while read -r p; do kill "$p" 2>/dev/null; done < "$T/pids"; wait 2>/dev/null; }
run() { UNITOTEM_ACPI_DIR="$T/i" UNITOTEM_ACPI_SAMPLE=1 UNITOTEM_ACPI_STORM_LIMIT=2000 sh "$SCRIPT"; }

reset; mk gpe03 10000; mk gpe66 5; mk gpe0A 100
printf '5000000  \n' > "$T/i/sci"; printf '5000000  \n' > "$T/i/gpe_all"
# "mask" written by the script goes to the file: the ticker watches a marker instead, set by this wrapper around the file
( while sleep 0.05; do grep -q '^mask' "$T/i/gpe03" 2>/dev/null && echo 1 > "$T/i/gpe03.masked"; done ) & echo $! >> "$T/pids"
run; rc=$?
sleep 0.3
check "the guard exits 0" [ "$rc" = 0 ]
check "the storming event is written 'mask'" grep -q '^mask' "$T/i/gpe03"
check "it is logged with its rate" grep -qE 'masked ACPI event gpe03: [0-9]+ events per second' "$T/log"
check "a quiet event is left alone" bash -c "! grep -q '^mask' '$T/i/gpe66' && ! grep -q '^mask' '$T/i/gpe0A'"
check "sci and gpe_all are not events: left alone" bash -c "! grep -q '^mask' '$T/i/sci' && ! grep -q '^mask' '$T/i/gpe_all'"
check "exactly one event masked" [ "$(grep -c masked "$T/log")" = 1 ]
stop

reset; mk gpe03 5; mk gpe66 50
run; sleep 0.2
check "a machine with no storm: nothing is masked or logged" bash -c "! grep -q '^mask' '$T/i/gpe03' && ! grep -q '^mask' '$T/i/gpe66' && [ ! -s '$T/log' ]"
stop

reset; mk gpe03 3000; mk gpe05 20000
( while sleep 0.05; do for g in gpe03 gpe05; do grep -q '^mask' "$T/i/$g" 2>/dev/null && echo 1 > "$T/i/$g.masked"; done; done ) & echo $! >> "$T/pids"
run; sleep 0.3
check "two storming events are both masked" bash -c "grep -q '^mask' '$T/i/gpe03' && grep -q '^mask' '$T/i/gpe05' && [ \$(grep -c masked '$T/log') = 2 ]"
stop

check "a missing directory is not an error" env UNITOTEM_ACPI_DIR="$T/nonexistent" sh "$SCRIPT"
check "a bad limit is refused" bash -c "! UNITOTEM_ACPI_DIR='$T' UNITOTEM_ACPI_STORM_LIMIT='1;rm -rf /' sh '$SCRIPT'"
check "a zero sample is refused" bash -c "! UNITOTEM_ACPI_DIR='$T' UNITOTEM_ACPI_SAMPLE=0 sh '$SCRIPT'"
check "the script is POSIX sh (dash parses it)" bash -c "command -v dash >/dev/null && dash -n '$SCRIPT' || sh -n '$SCRIPT'"
echo "$ok passed, $fail failed"; [ "$fail" = 0 ]

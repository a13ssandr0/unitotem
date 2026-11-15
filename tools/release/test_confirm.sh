#!/bin/bash
# Test of the one confirmation of the deploy scripts (`confirm` in deploy/script/lib.sh, and the same rule in write-sd.sh): "(y/n)", y or yes in any
# case accepts, anything else declines; no script keeps the old "[type YES]" prompt. Pure bash, nothing on the host is touched.
#   tools/release/test_confirm.sh
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ok=0 fail=0
check() { if "${@:2}" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
eval "$(sed -n '/^confirm() {/,/^}/p' "$DIR/deploy/script/lib.sh")"
ask() { printf '%b' "$1" | confirm "Proceed?" 2>/dev/null; }

for a in y Y yes YES Yes yEs; do check "'$a' accepts" ask "$a\n"; done
for a in n N no NO "" maybe "type YES" yy "yes please" " "; do check "'$a' declines" bash -c "! printf '%b' '$a\n' | { $(declare -f confirm); confirm Proceed? 2>/dev/null; }"; done
check "end of input declines" bash -c "! { $(declare -f confirm); confirm Proceed? </dev/null 2>/dev/null; }"
check "the prompt is 'TEXT (y/n) '" bash -c "[ \"\$(echo y | { $(declare -f confirm); confirm 'Erase it?' 2>&1 >/dev/null; })\" = 'Erase it? (y/n) ' ]"
check "no deploy script keeps '[type YES]' or '[y/N]'" bash -c "! grep -rnE 'type YES|Type .YES.|\\[y/N\\]' $DIR/deploy/script/*.sh"
check "write-sd.sh accepts y and yes in any case" bash -c "grep -q 'case \"\${answer,,}\" in y|yes)' $DIR/deploy/script/write-sd.sh"
echo "$ok passed, $fail failed"; [ "$fail" = 0 ]

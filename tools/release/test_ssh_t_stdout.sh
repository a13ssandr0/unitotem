#!/bin/bash
# ssh_t is used inside pipelines whose stdout is data (the backup streams): the escalation set-up it runs on first use must not write to stdout.
#   tools/release/test_ssh_t_stdout.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail=0
for mode in sudo-n password; do
    out=$(MODE=$mode bash -c '
        source deploy/lib.sh
        SSH_OPTS=(); TARGET_USERHOST=pi@10.0.0.1; OTA_AUTH=password
        _sshpass() { [ "$MODE" = sudo-n ] && return 0; case "$*" in *"sudo -n true"*) return 1 ;; *) return 0 ;; esac; }
        TARGET_PRIV_READY=""; setup_target_privilege 2>/dev/null' 2>/dev/null)
    if [ -z "$out" ]; then echo "PASS: setup_target_privilege ($mode) writes nothing to stdout"; else echo "FAIL: setup_target_privilege ($mode) wrote to stdout: $out"; fail=1; fi
done
exit $fail

#!/bin/bash
# Does the recovery initrd carry every external command the OTA engine runs?
#   check-recovery-commands.sh ROOTFS INITRD ENGINE.sh
# The engine runs inside that initramfs, where only what unitotem/files/ota-hook copied exists. A command that is in the image but not in the
# initrd fails there, at the worst moment (`tr` and `cmp` were missing for the amd64 A/B and Secure Boot paths: set-default-recovery and
# populate-bootfs --secure-boot shim died mid-deploy; found by actually running an install from Windows, not by any check).
# Heuristic: words in command position in the engine, that exist as executables in the image (so strings, arithmetic and case labels are
# ignored) and are not shell builtins/keywords/engine functions. ALLOW lists the ones that legitimately run elsewhere or are optional.
set -uo pipefail
R="$1"; INITRD="$2"; ENG="$3"
ALLOW=" grub-mkconfig update-grub grub-install grub-reboot zstd unzstd dpkg apt-get systemctl journalctl "   # run in the target's chroot, or only for sets we never build
have=$(lsinitramfs "$INITRD" 2>/dev/null | sed 's|.*/||' | sort -u) || exit 2
[ -n "$have" ] || { echo "lsinitramfs: nothing listed for $INITRD" >&2; exit 2; }
funcs=$(grep -oE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)' "$ENG" | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)//')
missing=""; n=0
# comments and heredoc bodies are dropped crudely; quoted strings stay (the "exists in the image" filter removes most of their words)
words=$(awk '
    skip != "" { if ($0 ~ "^[[:space:]]*" skip "[[:space:]]*$") skip = ""; next }
    /^[[:space:]]*#/ { next }
    { if (match($0, /<<-?[[:space:]]*["\x27]?[A-Za-z_]+/)) { t = substr($0, RSTART, RLENGTH); gsub(/<<-?[[:space:]]*["\x27]?/, "", t); heredoc = t } else heredoc = ""
      line = $0; sub(/[[:space:]]#.*$/, "", line); print line; if (heredoc != "") skip = heredoc }' "$ENG" \
    | grep -oE '(^|[|;&(`{]|\$\(|\bthen\b|\bdo\b|\belse\b)[[:space:]]*[a-z][a-z0-9._+-]+([[:space:]]|$)' \
    | sed -E 's/^[|;&(`{$[:space:]]*//; s/^(then|do|else)[[:space:]]*//; s/[[:space:]]+$//' | sort -u)
for w in $words; do
    case " $ALLOW " in *" $w "*) continue ;; esac
    t=$(type -t "$w" 2>/dev/null || true); case "$t" in builtin|keyword) continue ;; esac
    grep -qxF -- "$w" <<<"$funcs" && continue
    found=0; for d in usr/sbin usr/bin sbin bin; do [ -x "$R/$d/$w" ] && { found=1; break; }; done
    [ "$found" = 1 ] || continue
    n=$((n + 1))
    grep -qxF -- "$w" <<<"$have" || missing="$missing $w"   # here-strings: with pipefail, grep -q closing the pipe early reports a false failure
done
echo "engine commands checked: $n"
if [ -n "$missing" ]; then echo "MISSING from the recovery initrd:$missing" >&2; exit 1; fi

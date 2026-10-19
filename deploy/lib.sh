#!/bin/bash
# Shared host-side helpers for deploy/remote-deploy.sh and deploy/make-parts.sh.
# Not meant to be executed directly.

log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die()  { echo "*** $*" >&2; exit 1; }

require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "Comandi mancanti sull'host: ${missing[*]}"
}

# Partition device suffix, mirrors iso/installer.sh's pdev():
# /dev/sda -> /dev/sda1 ; /dev/nvme0n1|/dev/mmcblk0 -> ...p1
pdev() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ (nvme|mmcblk) ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Parse a size like "12G", "512M", "838415552" (bytes, optionally with a unit
# suffix as used by truncate/parted) into raw bytes.
size_to_bytes() {
    local s="$1" num unit
    if [[ "$s" =~ ^([0-9]+)([KMGTkmgt]?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]^^}"
        case "$unit" in
            K) echo $((num * 1024)) ;;
            M) echo $((num * 1024 * 1024)) ;;
            G) echo $((num * 1024 * 1024 * 1024)) ;;
            T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
            *) echo "$num" ;;
        esac
    else
        die "Dimensione non riconosciuta: $s"
    fi
}

bytes_human() {
    local b=$1
    awk -v b="$b" 'BEGIN {
        split("B K M G T", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf "%.1f%s", b, u[i]
    }'
}

# ssh/scp wrappers for the ORIGINAL system and for the OTA session (dropbear
# inside the fallback/recovery initramfs, port 2222, host key generated
# fresh every boot - TOFU/accept-new is the deliberate trust model there,
# not a baked-in shared key). Both authenticate with a fixed, known
# password rather than SSH keys.
#
# An earlier version of this authenticated with BatchMode=yes (keys only),
# on the assumption that trust already established elsewhere (the real
# system's own authorized_keys, or the operator's local identity) could
# just be propagated to wherever it was needed next. In practice that meant
# a whole chain of propagation steps - unitotem-ota-arm copying the real
# system's authorized_keys into unitotem-ota.conf, a separate path for
# never-deployed targets that have no such file to copy - that keeps having
# a moving part something else hasn't provisioned yet, without buying any
# real security margin for this project's threat model: physical access to
# the device already exposes as much or more (same reasoning already
# applied to not deleting the WiFi PSK after use). A single password,
# already used for interactive access to every device in this project, is
# simpler and was already proven working before any of the key machinery
# was added.
OTA_PASSWORD="${OTA_PASSWORD:-unitotem}"
# The password of root in the FALLBACK (initramfs dropbear) and of the freshly installed UniTotem system: fixed by the image, NOT the login
# password of the machine being adopted. OTA_PASSWORD may be that machine's own user password (e.g. a desktop PC reached as tv@host); using it
# for the fallback made the deploy wait forever for a session that was up (authentication silently refused).
OTA_FALLBACK_PASSWORD="${OTA_FALLBACK_PASSWORD:-unitotem}"

# NON_INTERACTIVE_SSH_ASKPASS_REQUIRE=never + `env -u DISPLAY -u SSH_ASKPASS`
# is load-bearing, not decoration: without it, ssh can fall back to a
# graphical ssh-askpass popup on the user's own desktop even with sshpass -p
# given explicitly (confirmed happening for real earlier this project).
_sshpass() {
    SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS \
        sshpass -p "$OTA_PASSWORD" "$@"
}

SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no \
          -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

# ---------------------------------------------------------------------------
# Privilege on the REAL system's channel.
#
# Logging in as root is not a realistic requirement: a device being adopted
# runs whatever OS it shipped with, and every mainstream one - Raspberry Pi
# OS included - disables root SSH and leaves root with no password. Yet
# nearly everything done to a running target is privileged: reading block
# devices to probe them (blkid, dumpe2fs), writing the boot partition,
# rebooting. So when the login user is not root, escalate with sudo.
#
# sudo -A (askpass helper) rather than sudo -S (password on stdin), because
# several call sites pipe a script into `bash -s` and -S would eat it. The
# helper is written to the target's own /tmp with umask 077 and removed by
# clear_target_privilege.
#
# None of this touches ota_ssh/ota_ssh_send: the fallback's dropbear always
# runs as root, so the OTA session never needs escalation.
# ---------------------------------------------------------------------------
TARGET_SUDO=""
TARGET_PRIV_READY=""
OTA_ASKPASS_REMOTE="/tmp/.unitotem-ota-askpass"

setup_target_privilege() {
    [ -n "$TARGET_PRIV_READY" ] && return 0
    local user="${TARGET_USERHOST%%@*}"
    [ "$user" != "${TARGET_USERHOST}" ] || user="$(id -un)"   # no "user@" given
    if [ "$user" = root ]; then
        TARGET_SUDO=""
        TARGET_PRIV_READY=1
        return 0
    fi
    if _sshpass ssh -n "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "sudo -n true" >/dev/null 2>&1; then
        TARGET_SUDO="sudo -n"
        log "Target: utente '${user}', sudo senza password."
    else
        # Written via a heredoc rather than an echo'd string so the password
        # never has to survive a round of shell quoting. No -n here: this one
        # call deliberately uses stdin.
        _sshpass ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" \
            "umask 077; cat > ${OTA_ASKPASS_REMOTE} && chmod 700 ${OTA_ASKPASS_REMOTE}" <<EOF || die "impossibile preparare l'helper sudo sul target"
#!/bin/sh
printf '%s\n' '${OTA_PASSWORD}'
EOF
        TARGET_SUDO="SUDO_ASKPASS=${OTA_ASKPASS_REMOTE} sudo -A"
        _sshpass ssh -n "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "${TARGET_SUDO} true" >/dev/null 2>&1 \
            || die "privilegi di root non ottenibili sul target come '${user}': sudo assente, negato, o password errata"
        log "Target: utente '${user}', escalation via sudo con password."
    fi
    TARGET_PRIV_READY=1
}

# Deliberately does NOT consult TARGET_SUDO. The probe runs ssh_t inside a
# command substitution, so the escalation state is established in a subshell
# and the parent - where the EXIT trap fires - never sees it. Keying the
# cleanup off that state meant the helper, which holds the target password,
# survived the run. Just attempt the removal whenever we logged in as
# somebody other than root; it is a single cheap call and cannot be skipped
# by state that got lost in a subshell.
clear_target_privilege() {
    [ -n "${TARGET_USERHOST:-}" ] || return 0
    local user="${TARGET_USERHOST%%@*}"
    [ "$user" != "${TARGET_USERHOST}" ] || return 0   # no "user@" part given
    [ "$user" != root ] || return 0
    _sshpass ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${TARGET_USERHOST}" \
        "rm -f ${OTA_ASKPASS_REMOTE}" >/dev/null 2>&1 || true
}

# Runs a command on the target with root privileges, escalating only when
# needed. Two call shapes are supported and they are NOT interchangeable:
#   ssh_t "a; b"            - one string, run inside a privileged shell so
#                             that every command in it is privileged, not
#                             just the first (plain "sudo a; b" would leave
#                             b unprivileged - that would silently skip a
#                             reboot, for instance).
#   ssh_t bash -s -- x y    - argv form, stdin left free to carry a script.
ssh_t() {
    setup_target_privilege
    if [ -z "${TARGET_SUDO}" ]; then
        _sshpass ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "$@"
    elif [ $# -eq 1 ]; then
        local quoted; quoted=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
        _sshpass ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "${TARGET_SUDO} sh -c '${quoted}'"
    else
        _sshpass ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "${TARGET_SUDO}" "$@"
    fi
}

# -O forces the legacy SCP protocol instead of SFTP. Recent OpenSSH defaults
# scp to SFTP, and this project's own image ships an sshd_config with no
# "Subsystem sftp" line at all, so the default fails outright with
# "subsystem request failed on channel 0". Legacy mode needs nothing but a
# shell on the far end, which is exactly what is guaranteed here.
scp_t() {
    _sshpass scp -O -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o ConnectTimeout=10 "$@"
}

# Copy a local file to a target path that may require root. scp itself cannot
# escalate, so when escalation is needed the file lands in the login user's
# /tmp first and is moved into place privileged.
scp_root() {
    local src="$1" dest="$2"
    setup_target_privilege
    if [ -z "${TARGET_SUDO}" ]; then
        scp_t "$src" "${TARGET_USERHOST}:${dest}"
        return
    fi
    local tmp="/tmp/.unitotem-ota-upload.$$"
    scp_t "$src" "${TARGET_USERHOST}:${tmp}" || return 1
    # chown because the file arrives owned by the login user, having passed
    # through their /tmp. Tolerated failure: the usual destination is the
    # vfat boot partition, which has no concept of ownership.
    ssh_t "mv -f '${tmp}' '${dest}' && { chown root:root '${dest}' 2>/dev/null || true; }" \
        || { ssh_t "rm -f '${tmp}'" >/dev/null 2>&1; return 1; }
}

# $1 = host, rest = command.
# ServerAlive* mirrors SSH_OPTS and is not cosmetic symmetry: the very last
# thing run_ota_sequence does over this channel is tell the target to reboot
# into the trial system. The machine then disappears mid-session, and with
# no keepalive ssh waits on a TCP connection that will never answer - seen
# for real, a deploy sat wedged for over eleven minutes AFTER the target had
# already rebooted and come up healthy, until the outer timeout killed it.
# With these, the dead peer is noticed in ~15s and the deploy moves on to
# waiting for the real system.
OTA_SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no \
              -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
              -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p "${OTA_PORT:-2222}")

# -n (stdin from /dev/null) is load-bearing here, not tidiness. ssh without
# it forwards its own stdin to the remote command, and run_ota_sequence
# calls this from inside a loop that reads parts.manifest - so the first
# restore-part would swallow the rest of the manifest and every partition
# block after it silently disappeared. Real consequence, seen on hardware:
# on a from-scratch deploy the DATA block was never reached, data-op never
# ran, DATA was left with a GPT name but NO filesystem, and everything
# downstream that keys off `blkid -L DATA` (the /etc overlay, and through it
# a writable /etc and unitotem-ssh-hostkey) failed. It was invisible on an
# already-provisioned target, where DATA already had a filesystem.
# ota_ssh_send below is the deliberate counterpart: it MUST keep stdin to
# pipe payloads, which is exactly why the two are separate functions.
ota_ssh() {
    local host="$1"; shift
    OTA_PASSWORD="$OTA_FALLBACK_PASSWORD" _sshpass ssh -n "${OTA_SSH_OPTS[@]}" "root@${host}" "$@"
}

ota_ssh_send() {
    # Pipe stdin to a remote command over the OTA session - used to push
    # the recovery kernel/initrd and the boot-fs filecopy tarball onto the
    # control channel (small, one-shot files; bulk partition data always
    # goes over the plain-netcat DATA channel instead, see restore-part).
    local host="$1"; shift
    OTA_PASSWORD="$OTA_FALLBACK_PASSWORD" _sshpass ssh "${OTA_SSH_OPTS[@]}" "root@${host}" "$@"
}

# Wait until something is listening on $2/tcp on this host, up to $3
# seconds (default 10). Used before telling a target to pull from the DATA
# channel - never via a throwaway probe connection (see the plan/history:
# a -z probe consuming the target's one-shot listener was a real bug in the
# previous design).
wait_port_bound() {
    local port="$1" timeout="${2:-10}" waited=0
    while ! ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; do
        sleep 0.2
        waited=$((waited + 1))
        [ "$waited" -lt $((timeout * 5)) ] || return 1
    done
}

# Serve one file over plain TCP on $2/tcp, backgrounded, for the target to
# pull via /dev/tcp - the DATA channel side of every restore-part/populate-
# bootfs call. Prints the socat PID.
#
# socat's stdout/stderr MUST be redirected away from the function's own -
# confirmed as a real hang on hardware, not theoretical: every caller uses
# `pid=$(serve_file_once ...)`, and command substitution doesn't return
# until EOF on the pipe it captures, i.e. until *every* process holding that
# pipe's write end closes it. Without the redirect, the backgrounded socat
# inherits a copy of that same write end and keeps it open for its entire
# (long) listening lifetime, so `$(serve_file_once ...)` never returns at
# all - restore-part's own ota_ssh call is never even reached, which is
# exactly what made this look like a stuck transfer instead of a shell
# scripting bug: nothing on the target side ever started.
serve_file_once() {
    local file="$1" port="$2"
    socat -u "FILE:${file}" "TCP-LISTEN:${port},reuseaddr" >/dev/null 2>&1 &
    echo $!
}

# Read a KEY=VALUE manifest (parts.manifest, recovery.manifest, or an
# ota-engine.sh subcommand's own KEY=VALUE stdout) into the associative
# array named by $1, one blank-line-terminated block per call (rewinds to
# the next block on each invocation so a multi-block file - the parts
# manifest's header + per-partition blocks - can be walked block by block).
read_kv_block() {
    local -n _out="$1"
    _out=()
    local line key val
    while IFS= read -r line; do
        [ -z "$line" ] && return 0
        key=${line%%=*}; val=${line#*=}
        _out["$key"]="$val"
    done
    [ ${#_out[@]} -gt 0 ]
}

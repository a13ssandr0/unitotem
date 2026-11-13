#!/bin/bash
# Shared host-side helpers for deploy/remote-deploy.sh and deploy/make-parts.sh.
# Not meant to be executed directly.
# Auth modes of the REAL system's ssh/scp, fixed when this file is sourced (set OTA_AUTH before sourcing):
#   OTA_AUTH=password (default): sshpass with OTA_PASSWORD, password options only.
#   OTA_AUTH=key: no sshpass, BatchMode with public keys only: a password is never asked.
# The OTA fallback (port 2222) has its own credentials (ota_auth_for), whatever OTA_AUTH is.

log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die()  { echo "*** $*" >&2; exit 1; }

require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "Missing commands on the host: ${missing[*]}"
}

# Partition device name: /dev/sda -> /dev/sda1 ; /dev/nvme0n1|/dev/mmcblk0 -> ...p1
pdev() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ (nvme|mmcblk) ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Parse a size like "12G", "512M", "838415552" (bytes, optional truncate/parted unit suffix) into bytes.
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
        die "Unrecognised size: $s"
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

# ssh/scp wrappers for the ORIGINAL system and for the OTA session (dropbear inside the fallback/recovery
# initramfs, port 2222, host key generated fresh every boot: accept-new is the trust model there).
# OTA_PASSWORD: the login password of the ADOPTED system (not the fallback's).
OTA_PASSWORD="${OTA_PASSWORD:-unitotem}"
# OTA fallback credentials (port 2222). Read from the environment only, never defaulted, never on a command line:
#   OTA_FALLBACK_KEY=PATH       private key; default: the per-target key (ota_key_path) when it exists
#   OTA_FALLBACK_USER=NAME      login user of the fallback (default root)
#   OTA_FALLBACK_PASSWORD=...   password, used when no key is available
#   OTA_FALLBACK_OPEN=1         empty password: first access to a device with no admin and no key
# Selection and errors: ota_auth_for.
OTA_FALLBACK_USER="${OTA_FALLBACK_USER:-root}"

OTA_AUTH="${OTA_AUTH:-password}"
case "$OTA_AUTH" in
    password|key) ;;
    *) die "OTA_AUTH must be 'password' or 'key' (got '${OTA_AUTH}')" ;;
esac

# SSH_ASKPASS_REQUIRE=never + `env -u DISPLAY -u SSH_ASKPASS` are required: without them ssh can fall
# back to a graphical askpass popup even with sshpass -p.
# Always the password path: the OTA fallback calls this directly.
_sshpass_pw() {
    SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS \
        sshpass -p "$OTA_PASSWORD" "$@"
}

# The real system's channel: password mode through sshpass, key mode runs the command as is.
_sshpass() {
    if [ "$OTA_AUTH" = key ]; then
        SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS "$@"
    else
        _sshpass_pw "$@"
    fi
}

if [ "$OTA_AUTH" = key ]; then
    SSH_OPTS=(-o BatchMode=yes -o PreferredAuthentications=publickey \
              -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
    SCP_OPTS=(-o BatchMode=yes -o PreferredAuthentications=publickey -o ConnectTimeout=10)
else
    SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no \
              -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
    SCP_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10)
fi

# Privilege on the REAL system's channel: a device being adopted usually has root SSH disabled, yet nearly
# everything done to a target is privileged, so escalate with sudo when the login user is not root.
# sudo -A (askpass helper), not -S, because several call sites pipe a script into `bash -s`. The helper lives in the
# target's /tmp (umask 077) and is removed by clear_target_privilege. ota_ssh/ota_ssh_send never need it: the
# fallback's dropbear runs as root.
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
        log "Target: user '${user}', sudo without password." >&2   # stderr: ssh_t runs inside pipelines whose stdout is data (backup streams)
    else
        # Key mode never escalates with a password: sudo -n only.
        [ "$OTA_AUTH" = password ] || die "cannot run 'sudo -n' on the target as '${user}': key mode needs passwordless sudo"
        # Written via a heredoc so the password does not go through shell quoting. No -n: this call uses stdin.
        _sshpass ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" \
            "umask 077; cat > ${OTA_ASKPASS_REMOTE} && chmod 700 ${OTA_ASKPASS_REMOTE}" <<EOF || die "cannot set up the sudo helper on the target"
#!/bin/sh
printf '%s\n' '${OTA_PASSWORD}'
EOF
        TARGET_SUDO="SUDO_ASKPASS=${OTA_ASKPASS_REMOTE} sudo -A"
        _sshpass ssh -n "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "${TARGET_SUDO} true" >/dev/null 2>&1 \
            || die "cannot obtain root on the target as '${user}': sudo missing, denied, or wrong password"
        log "Target: user '${user}', escalation via sudo with password." >&2
    fi
    TARGET_PRIV_READY=1
}

# Does NOT consult TARGET_SUDO: the probe runs ssh_t in a command substitution, so the escalation state
# lives in a subshell the parent (where the EXIT trap fires) never sees. The removal is attempted whenever
# the login user is not root, so the helper holding the target password never survives the run.
clear_target_privilege() {
    [ -n "${TARGET_USERHOST:-}" ] || return 0
    local user="${TARGET_USERHOST%%@*}"
    [ "$user" != "${TARGET_USERHOST}" ] || return 0   # no "user@" part given
    [ "$user" != root ] || return 0
    _sshpass ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=5 "${TARGET_USERHOST}" \
        "rm -f ${OTA_ASKPASS_REMOTE}" >/dev/null 2>&1 || true
}

# Runs a command on the target with root privileges, escalating only when needed. Two call shapes, NOT
# interchangeable:
#   ssh_t "a; b"            - one string, run inside a privileged shell so every command in it is
#                             privileged (plain "sudo a; b" would leave b unprivileged).
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

# -O forces the legacy SCP protocol: recent OpenSSH defaults scp to SFTP, and the image's sshd_config has
# no "Subsystem sftp" line ("subsystem request failed on channel 0"). Legacy mode needs only a shell.
scp_t() {
    _sshpass scp -O "${SCP_OPTS[@]}" "$@"
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
    # chown because the file arrives owned by the login user. Failure is tolerated: the usual destination
    # is the vfat boot partition, which has no ownership.
    ssh_t "mv -f '${tmp}' '${dest}' && { chown root:root '${dest}' 2>/dev/null || true; }" \
        || { ssh_t "rm -f '${tmp}'" >/dev/null 2>&1; return 1; }
}

# Common options of every OTA fallback connection (port 2222). Credentials are added by ota_auth_for.
# ServerAlive* is required: the last thing run_ota_sequence does over this channel is reboot the target into
# the trial system, which disappears mid-session; without keepalive ssh would wait on the dead connection.
# With it the dead peer is noticed in ~15s.
OTA_SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
              -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p "${OTA_PORT:-2222}")

# Per-target key of the OTA fallback, kept in the operator's state directory (never in the repository). The
# fallback accepts it once its public line is armed (unitotem-ota-arm --authkey-file, or the kernel cmdline).
ota_key_path() {
    local host="$1"
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || die "invalid host name for the OTA key: '${host}'"
    echo "${XDG_STATE_HOME:-$HOME/.local/state}/unitotem-deploy/${host//:/_}/id_ed25519"
}

# Creates the per-target key when missing (ed25519, no passphrase) and returns its private key path.
ota_key_ensure() {
    local host="$1" key dir
    key=$(ota_key_path "$host") || die "invalid OTA host '${host}'"
    dir=$(dirname "$key")
    ( umask 077 && mkdir -p -m 0700 "$dir" ) || die "cannot create ${dir}"
    chmod 0700 "$dir" || die "cannot chmod 0700 ${dir}"
    if [ ! -f "$key" ]; then
        ( umask 077 && ssh-keygen -q -t ed25519 -N '' -C unitotem-deploy -f "$key" </dev/null ) \
            || die "ssh-keygen failed for ${key}"
    elif [ ! -f "$key.pub" ]; then
        ( umask 077 && ssh-keygen -y -f "$key" > "$key.pub" ) || die "cannot derive ${key}.pub"
    fi
    chmod 0600 "$key" || die "cannot chmod 0600 ${key}"
    echo "$key"
}

# Prints the public line of PATH.pub as "ssh-ed25519 BASE64" (comment stripped), or dies.
ota_key_publine() {
    local pub="$1.pub" line type b64 re='^ssh-ed25519 [A-Za-z0-9+/=]+$'
    [ -f "$pub" ] || die "public key not found: ${pub}"
    line=$(head -n 1 "$pub")
    read -r type b64 _ <<< "$line"
    line="${type} ${b64}"
    [[ "$line" =~ $re ]] || die "not an ssh-ed25519 public key: ${pub}"
    echo "$line"
}

# Chooses the key the fallback is armed with for HOST and sets OTA_ARM_KEY (private key path) and
# OTA_FALLBACK_KEY, so ota_ssh uses the same key at any address the fallback is found at (discover_fallback).
# Call WITHOUT command substitution: the globals must reach the caller. OTA_FALLBACK_KEY set by the user wins.
ota_arm_key() {
    local host="$1"
    if [ -n "${OTA_FALLBACK_KEY:-}" ]; then
        [ -f "$OTA_FALLBACK_KEY" ] || die "OTA_FALLBACK_KEY not found: ${OTA_FALLBACK_KEY}"
        if [ ! -f "$OTA_FALLBACK_KEY.pub" ]; then
            ( umask 077 && ssh-keygen -y -f "$OTA_FALLBACK_KEY" > "$OTA_FALLBACK_KEY.pub" ) \
                || die "cannot derive ${OTA_FALLBACK_KEY}.pub"
        fi
    else
        local key
        key=$(ota_key_ensure "$host") || die "cannot prepare the OTA key for ${host}"
        OTA_FALLBACK_KEY="$key"
    fi
    OTA_ARM_KEY="$OTA_FALLBACK_KEY"
}

# Selects the credentials for HOST and sets OTA_AUTH_MODE (key|open|password), OTA_AUTH_OPTS (ssh options)
# and OTA_AUTH_TARGET (user@host). Order: OTA_FALLBACK_KEY, the per-target key of HOST, OTA_FALLBACK_OPEN=1,
# OTA_FALLBACK_PASSWORD. Dies when none is set.
ota_auth_for() {
    local host="$1" key="" user="${OTA_FALLBACK_USER:-root}"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid OTA fallback user: '${user}'"
    OTA_AUTH_TARGET="${user}@${host}"
    if [ -n "${OTA_FALLBACK_KEY:-}" ]; then
        [ -f "$OTA_FALLBACK_KEY" ] || die "OTA_FALLBACK_KEY not found: ${OTA_FALLBACK_KEY}"
        key="$OTA_FALLBACK_KEY"
    else
        key=$(ota_key_path "$host") || die "invalid OTA host '${host}'"
    fi
    if [ -n "$key" ] && [ -f "$key" ]; then
        OTA_AUTH_MODE=key
        OTA_AUTH_OPTS=(-o BatchMode=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
                       -o IdentitiesOnly=yes -i "$key")
    elif [ "${OTA_FALLBACK_OPEN:-0}" = 1 ]; then
        OTA_AUTH_MODE=open
        OTA_AUTH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
    elif [ -n "${OTA_FALLBACK_PASSWORD:-}" ]; then
        OTA_AUTH_MODE=password
        OTA_AUTH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
    else
        die "no OTA fallback credentials for ${host}: set OTA_FALLBACK_KEY, or OTA_FALLBACK_USER with OTA_FALLBACK_PASSWORD, or OTA_FALLBACK_OPEN=1"
    fi
}

# Runs ssh with the options chosen by ota_auth_for. Password and open modes go through sshpass -e: the password
# reaches sshpass in its environment (SSHPASS), not on the command line. Key mode runs ssh without sshpass.
_ota_ssh_exec() {
    if [ "$OTA_AUTH_MODE" = key ]; then
        SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS \
            ssh "${OTA_SSH_OPTS[@]}" "${OTA_AUTH_OPTS[@]}" "$@"
    else
        local pw="${OTA_FALLBACK_PASSWORD:-}"
        [ "$OTA_AUTH_MODE" = open ] && pw=""
        SSHPASS="$pw" SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS \
            sshpass -e ssh "${OTA_SSH_OPTS[@]}" "${OTA_AUTH_OPTS[@]}" "$@"
    fi
}

# -n (stdin from /dev/null) is required: ssh would otherwise forward its stdin to the remote command, and
# run_ota_sequence calls this inside a loop that reads parts.manifest, so the first restore-part would
# swallow the rest of the manifest. ota_ssh_send below keeps stdin to pipe payloads, hence two functions.
ota_ssh() {
    local host="$1"; shift
    ota_auth_for "$host"
    _ota_ssh_exec -n "$OTA_AUTH_TARGET" "$@"
}

ota_ssh_send() {
    # Pipe stdin to a remote command over the OTA session: used for the recovery kernel/initrd and the
    # boot-fs filecopy tarball (small files; bulk partition data goes over the plain-netcat DATA channel,
    # see restore-part).
    local host="$1"; shift
    ota_auth_for "$host"
    _ota_ssh_exec "$OTA_AUTH_TARGET" "$@"
}

# Wait until something is listening on $2/tcp on this host, up to $3
# seconds (default 10). Used before telling a target to pull from the DATA channel; never probe with a
# throwaway connection, which would consume the one-shot listener.
wait_port_bound() {
    local port="$1" timeout="${2:-10}" waited=0
    while ! ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .; do
        sleep 0.2
        waited=$((waited + 1))
        [ "$waited" -lt $((timeout * 5)) ] || return 1
    done
}

# Serve one file over plain TCP on $2/tcp, backgrounded, for the target to pull via /dev/tcp (DATA channel of
# restore-part/populate-bootfs). Prints the socat PID.
# socat's stdout/stderr MUST be redirected away: callers use `pid=$(serve_file_once ...)`, which would not return
# while the backgrounded socat holds the captured pipe.
serve_file_once() {
    local file="$1" port="$2"
    socat -u "FILE:${file}" "TCP-LISTEN:${port},reuseaddr" >/dev/null 2>&1 &
    echo $!
}

# Read a KEY=VALUE manifest (parts.manifest, recovery.manifest, or an ota-engine.sh subcommand's KEY=VALUE
# stdout) into the associative array named by $1, one blank-line-terminated block per call, so a multi-block
# file (the parts manifest's header + per-partition blocks) can be walked block by block.
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

# backup_stream DIR NAME CMD...: runs CMD (it must write a tar stream on stdout), compresses the stream on this machine, checks that the
# archive reads back, and stores DIR/NAME.tar.zst (xz when zstd is missing) with a .sha256 next to it. Prints the archive path; fails
# (leaving nothing behind) when CMD, the compression or the read-back fails.
backup_stream() {
    local dir="$1" name="$2"; shift 2
    local comp="zstd -T0 -3" ext="tar.zst"
    command -v zstd >/dev/null 2>&1 || { comp="xz -T0 -3"; ext="tar.xz"; }
    mkdir -p "$dir" || return 1
    local out="${dir}/${name}.${ext}" part="${dir}/${name}.${ext}.part"
    ( set -o pipefail; "$@" | $comp > "$part" ) || { rm -f -- "$part"; return 1; }
    ( set -o pipefail; ${comp%% *} -dc "$part" | tar -tf - >/dev/null ) || { rm -f -- "$part"; return 1; }
    mv -f -- "$part" "$out" || return 1
    ( cd "$dir" && sha256sum "$(basename "$out")" > "${name}.sha256" ) || return 1
    echo "$out"
}

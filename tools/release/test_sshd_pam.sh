#!/bin/bash
# sshd/PAM test of the UniTotem login configuration in a debian:trixie container (OpenSSH 10.0p2).
# Usage: tools/release/test_sshd_pam.sh [A|B|both]   (default: both)
#   B     unitotem/files/sshd_config (UsePAM yes): every assertion
#   A     the sshd_config before 6d22c95 (no UsePAM yes): reference only, its lines carry the prefix `ref`
#   both  A as reference, then B; the exit code is B's
#   A     alone exits 2: no B assertion ran
# Proves, for B, over real ssh connections to 127.0.0.1 (no real device):
#   first access (root open, empty password, first-admin script): the script is the only thing reached, no shell,
#     no sftp listing, no scp transfer, no -L/-D/-R forward, no tunnel, no key other than the installed one;
#   root outside the marker group is refused (no credentials, auth none, empty password, key);
#   root closed (password `*`): password, empty password, `*` and auth none are refused, the installed key gives root;
#   admin: correct password and key log in, wrong password refused, locked-account password refused;
#   MaxAuthTries 5: six offered keys end in `Too many authentication failures`;
#   /etc/nologin refuses admin (password and key) and accepts root's key;
#   the MOTD header only in an interactive login, command output byte-exact (ssh printf, scp -O, ssh cat, rsync);
#   LANG forced to en_US.UTF-8 (SendEnv ignored); LD_PRELOAD not passed;
#   sshd -T: effective settings of root and admin outside the Match group; A and B differ only by usepam.
#   The Match Group block is checked at connection level (cells 1 and 2); sshd -T -C group= is unsupported here.
# Known A/B differences are printed as `info` lines computed from the observed results and never fail: locked-account
#   key login, expired-password key login, account expiry (usermod -e 1), /etc/nologin text, PAM environment and
#   limits, SFTP subsystem (absent in both configs), login wall times.
# Needs: docker (BuildKit) and debian:trixie (pulled online); ssh, ssh-keygen, ssh-keyscan, scp, sftp, rsync,
#   sshpass, openssl, git, setsid, timeout, awk, sha256sum, cmp, diff, python3. No root, no sudo.
# Containers: sshd-pam-test (image sshd-pam-img), listeners 127.0.0.1:22201 (A) and 127.0.0.1:22202 (B).
# Secrets (admin password, keys) are generated per run in a mktemp dir under ${TMPDIR:-/tmp}, read from files
#   (0600, dir 0700), never on a command line. The container, the image and the temp dir are removed on exit.
#   SSHD_PAM_LOG_DIR=DIR keeps the transcripts (build.log, log-A.log, log-B.log) in DIR.

set -u

MODE=${1:-both}
case "$MODE" in
    A|B|both) ;;
    *) echo "usage: $0 [A|B|both]" >&2; exit 2 ;;
esac

HERE=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
U=$HERE/unitotem
M=$HERE/unitotem-manager
TMPBASE=${TMPDIR:-/tmp}
T=$(mktemp -d "$TMPBASE/sshd-pam.XXXXXX") || exit 1
SEC=$T/sec
W=$T/work
CTX=$T/ctx

cleanup() {
    local parent name
    docker rm -f sshd-pam-test >/dev/null 2>&1
    docker rmi sshd-pam-img >/dev/null 2>&1
    if [ -n "${SSHD_PAM_LOG_DIR:-}" ] && [ -d "$SSHD_PAM_LOG_DIR" ]; then
        cp -f "$T/build.log" "$T/work/log-A.log" "$T/work/log-B.log" "$SSHD_PAM_LOG_DIR"/ 2>/dev/null
    fi
    case "$T" in
        "$TMPBASE"/sshd-pam.*) ;;
        *) echo "cleanup: temp dir not removed (outside $TMPBASE): $T" >&2; return 1 ;;
    esac
    [ -n "$T" ] && [ -d "$T" ] || return 0
    rm -rf -- "$T" 2>/dev/null
    if [ -d "$T" ]; then
        # root-owned leftovers from a container: removed by a disposable container, never sudo
        parent=${T%/*}
        name=${T##*/}
        docker run --rm -v "$parent:/w" debian:trixie rm -rf -- "/w/$name" >/dev/null 2>&1
        [ -d "$T" ] && rm -rf -- "$T" 2>/dev/null
    fi
    [ -d "$T" ] && echo "cleanup: temp dir still present: $T" >&2
    return 0
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# ---- counters, output and summary ---------------------------------------------------------------------------

OK_N=0
FAIL_N=0
REF_OK=0
REF_FAIL=0
C12_CFG=""        # A or B; empty = cross-config and build lines (count as B)
declare -A REC=()

# _c12_check NAME HOLDS(0|1) DETAIL: prints ok/FAIL, counts (config A counts as ref)
_c12_check() {
    local pfx=
    [ "$C12_CFG" = A ] && pfx="ref "
    if [ "$2" = 0 ]; then
        echo "${pfx}ok $1"
        if [ "$C12_CFG" = A ]; then REF_OK=$((REF_OK + 1)); else OK_N=$((OK_N + 1)); fi
    else
        echo "${pfx}FAIL $1${3:+ ($3)}"
        if [ "$C12_CFG" = A ]; then REF_FAIL=$((REF_FAIL + 1)); else FAIL_N=$((FAIL_N + 1)); fi
    fi
}

# _info TEXT: a recorded value, never an assertion
_info() {
    local pfx=
    [ "$C12_CFG" = A ] && pfx="ref "
    echo "${pfx}info $*"
}

# finish: the summary line and the exit code (B only decides it)
finish() {
    if [ "$MODE" != B ]; then echo "ref result: $REF_OK ok, $REF_FAIL FAIL"; fi
    echo "result: $OK_N ok, $FAIL_N FAIL"
    if [ "$FAIL_N" != 0 ]; then exit 1; fi
    if [ "$MODE" = A ]; then exit 2; fi
    exit 0
}

# ---- helpers (lib of the fixture) ---------------------------------------------------------------------------

SP_CT=sshd-pam-test
SP_IMG=sshd-pam-img
C6_HDR='UniTotem (sshd-pam fixture)'
PW_ADMIN=$SEC/admin.pw
PW_EMPTY=$SEC/empty.pw
PW_WRONG=$SEC/wrong.pw
PW_STAR=$SEC/star.pw
KEY_ROOT=$SEC/id_root
KEY_ADMIN=$SEC/id_admin
KEY_OTHER=$SEC/id_other
WKEYS=("$SEC/wrong1" "$SEC/wrong2" "$SEC/wrong3" "$SEC/wrong4" "$SEC/wrong5" "$SEC/wrong6")
UP_FILE=$W/upload.txt
C12_LOG=$W/log-none.log
C12_PORT=""
C12_FP=""
C12_LISTEN=""
C12_BAN=""
C12_SOCKS=""
C12_OUT=""
C12_RC=0
C3_OUT=""
C3_ERRTXT=""
C3_RC=0
C3_LOGTXT=""
C3_HASH0=""
ERRF=$W/err.txt
BIN=$W/1m.bin
EXP_ABC=$W/abc.exp
BARE=$W/bare.out
BATCH=$W/sftp.batch
C4_RSHA=""
C4_LSHA=""
C4_RC=0
C4_ERRTXT=""
C4_ERR_INTER=""
C4_ERR_CMD=""
C4_OUT_INTER=""
C12_OPTS=(-F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
C12_CLIENT_ENV=(env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never)
C4_OPTS=(-F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5
         -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
C12_SOCKS_PY='
import socket, struct, sys
lp, tp = int(sys.argv[1]), int(sys.argv[2])
try:
    s = socket.create_connection(("127.0.0.1", lp), timeout=3)
except OSError as e:
    print("socks: no listener (%s)" % e.strerror)
    sys.exit(0)
s.settimeout(3)
s.sendall(b"\x05\x01\x00")
g = s.recv(2)
s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack(">H", tp))
r = s.recv(10)
print("socks greeting=%s reply=%s" % (g.hex(), r[:2].hex() if r else "none"))
if len(r) >= 2 and r[1] == 0:
    print("banner=" + s.recv(4).decode("latin-1"))
'

# sp_port CFG: host port of config A or B
sp_port() {
    case "$1" in
        A) echo 22201 ;;
        B) echo 22202 ;;
        *) echo "sp_port: CFG must be A or B" >&2; return 2 ;;
    esac
}

# sp_up: starts the container (if not running) and both sshd instances; waits (bounded) until both ports answer
sp_up() {
    local i cfg port ok
    if [ "$(docker inspect -f '{{.State.Running}}' "$SP_CT" 2>/dev/null)" != true ]; then
        docker rm -f "$SP_CT" >/dev/null 2>&1
        docker run -d --name "$SP_CT" \
            -p 127.0.0.1:22201:2201 -p 127.0.0.1:22202:2202 "$SP_IMG" >/dev/null || return 1
        docker exec "$SP_CT" sh -c 'mkdir -p /run/sshd && chmod 755 /run/sshd' || return 1
        docker exec -d "$SP_CT" /usr/sbin/sshd -f /etc/ssh/sshd_config.A -p 2201 \
            -E /var/log/sshd-A.log -o PidFile=/run/sshd-A.pid || return 1
        docker exec -d "$SP_CT" /usr/sbin/sshd -f /etc/ssh/sshd_config.B -p 2202 \
            -E /var/log/sshd-B.log -o PidFile=/run/sshd-B.pid || return 1
    fi
    for i in $(seq 1 20); do
        ok=1
        for cfg in A B; do
            port=$(sp_port "$cfg")
            timeout 5 ssh-keyscan -T 3 -p "$port" 127.0.0.1 >/dev/null 2>&1 || ok=0
        done
        [ "$ok" = 1 ] && return 0
        sleep 0.5
    done
    echo "sp_up: ports 22201/22202 did not answer" >&2
    return 1
}

# sp_exec ARGS...: runs a command in the container
sp_exec() {
    docker exec "$SP_CT" "$@"
}

# sp_ssh CFG [ssh args...]: key or no-password ssh, BatchMode=yes, no agent, no config file
sp_ssh() {
    local cfg="$1" port
    shift
    port=$(sp_port "$cfg") || return 2
    timeout 30 env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
        ssh -F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -o BatchMode=yes \
        -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -p "$port" "$@"
}

# sp_sshpass CFG FILE [ssh args...]: password test; FILE holds the password on its first line (0600)
sp_sshpass() {
    local cfg="$1" file="$2" port
    shift 2
    port=$(sp_port "$cfg") || return 2
    timeout 30 env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
        sshpass -f "$file" \
        ssh -F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -o BatchMode=no \
        -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -p "$port" "$@"
}

# sp_keys_install: root gets id_root, admin gets id_admin (admin must exist); id_other stays out
sp_keys_install() {
    docker exec -i "$SP_CT" sh -c 'install -d -m 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' \
        < "$KEY_ROOT.pub" || return 1
    docker exec -i "$SP_CT" sh -c 'install -d -m 700 -o admin -g admin /home/admin/.ssh && cat > /home/admin/.ssh/authorized_keys && chown admin:admin /home/admin/.ssh/authorized_keys && chmod 600 /home/admin/.ssh/authorized_keys' \
        < "$KEY_ADMIN.pub"
}

# sp_set_root_state open|nogroup|closed|locked: root's first-access state, as the image sets it
#   open     empty password, first-admin shell, marker group (first access open)
#   nogroup  empty password, first-admin shell, not in the marker group
#   closed   password '*', /bin/bash, not in the marker group (osusers.close_first_access)
#   locked   closed and locked with usermod -L
sp_set_root_state() {
    local inner leave='if id -nG root | tr " " "\n" | grep -qx unitotem-first-admin; then gpasswd -d root unitotem-first-admin >/dev/null; fi'
    case "$1" in
        open)    inner='passwd -d root >/dev/null && usermod -s /usr/sbin/unitotem-first-admin root && usermod -aG unitotem-first-admin root' ;;
        nogroup) inner="passwd -d root >/dev/null && usermod -s /usr/sbin/unitotem-first-admin root && $leave" ;;
        closed)  inner="$leave && usermod -p '*' root && usermod -s /bin/bash root" ;;
        locked)  inner="$leave && usermod -p '*' root && usermod -s /bin/bash root && usermod -L root" ;;
        *) echo "sp_set_root_state: open|nogroup|closed|locked" >&2; return 2 ;;
    esac
    docker exec "$SP_CT" sh -c "$inner"
}

# sp_admin_make: creates `admin` through the manager's first-access path (create_first_admin); closes the window
sp_admin_make() {
    docker exec -i "$SP_CT" python3 -I -c "import sys; sys.path.insert(0,'/usr/share/unitotem-manager'); from utils import first_access; first_access.create_first_admin('admin', sys.stdin.read().rstrip('\n'))" \
        < "$PW_ADMIN"
}

# sp_admin_remove: deletes `admin` with its home (as the manager does); root state is left as it is
sp_admin_remove() {
    docker exec "$SP_CT" deluser --remove-home -- admin
}

# _c12_sub TEXT WORD (substring), _c12_line TEXT LINE (whole line), _c12_linestart TEXT PREFIX,
# _c12_line_any TEXT WORD... (bash matching; no grep on the host)
_c12_sub() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
_c12_line() {
    local l
    while IFS= read -r l; do [ "$l" = "$2" ] && return 0; done <<<"$1"
    return 1
}
_c12_linestart() {
    local l
    while IFS= read -r l; do case $l in "$2"*) return 0 ;; esac; done <<<"$1"
    return 1
}
_c12_line_any() {
    local l w text=$1
    shift
    while IFS= read -r l; do
        for w in "$@"; do [ "$l" = "$w" ] && return 0; done
    done <<<"$text"
    return 1
}

# _c3_count TEXT PATTERN: number of lines of TEXT containing PATTERN
_c3_count() {
    local l n=0
    while IFS= read -r l; do
        case $l in *"$2"*) n=$((n + 1)) ;; esac
    done <<<"$1"
    echo "$n"
}

# _c12_log TEXT: appends to the transcript of the config
_c12_log() { printf '%s\n' "$*" >> "$C12_LOG"; }

# _verdict RC OUT USER: accepted when the probe exited 0 and printed exactly USER, else refused
_verdict() {
    if [ "$1" = 0 ] && [ "$2" = "$3" ]; then echo accepted; else echo refused; fi
}

# _rec KEY VALUE: records a value of the current config for the cross-config info lines
_rec() { REC["$C12_CFG.$1"]=$2; }

# _cross KEY LABEL: one computed info line, A and B values
_cross() {
    local a=${REC[A.$1]:-not run} b=${REC[B.$1]:-not run}
    echo "info $2: A $a, B $b"
}

# _c12_fresh: restarts both sshd listeners (same configs, same ports) so each probe starts with no per-source penalty.
# Observed: after ~40 failed or no-auth connections from one source, sshd drops every connection from it
# ("drop connection ... penalty"), which hides the login result.
_c12_fresh() {
    sp_exec sh -c '
        for c in A B; do p=/run/sshd-$c.pid; [ -s "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
        i=0
        while [ $i -lt 50 ]; do
            alive=0
            for c in A B; do p=/run/sshd-$c.pid; if [ -s "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; then alive=1; fi; done
            [ $alive = 0 ] && break
            sleep 0.1; i=$((i + 1))
        done
        /usr/sbin/sshd -f /etc/ssh/sshd_config.A -p 2201 -E /var/log/sshd-A.log -o PidFile=/run/sshd-A.pid
        /usr/sbin/sshd -f /etc/ssh/sshd_config.B -p 2202 -E /var/log/sshd-B.log -o PidFile=/run/sshd-B.pid
    ' >/dev/null 2>&1
}

# _c12_mark / _c12_since: line count of this config's sshd log before a probe, and the lines added after it
_c12_mark() {
    local m
    m=$(sp_exec sh -c 'wc -l < "$1"' sh "/var/log/sshd-$C12_CFG.log" 2>/dev/null | tr -d ' \n')
    echo "${m:-0}"
}
_c12_since() {
    sp_exec sh -c 'tail -n +"$2" "$1"' sh "/var/log/sshd-$C12_CFG.log" "$(($1 + 1))" 2>/dev/null \
        | tail -n 3 | cut -c1-200 | sed 's/^/sshd-log: /' >> "$C12_LOG"
}

# _c12_run NAME STDIN CMD...: runs CMD with STDIN piped in on fresh listeners; sets C12_OUT and C12_RC
_c12_run() {
    local name=$1 input=$2 m
    shift 2
    _c12_fresh
    m=$(_c12_mark)
    C12_OUT=$(printf '%s' "$input" | "$@" 2>&1)
    C12_RC=$?
    _c12_log "== $name"
    _c12_log "stdin: ${input:-<none>}"
    _c12_log "rc: $C12_RC"
    printf '%s\n' "$C12_OUT" | head -n 5 | sed 's/^/out: /' >> "$C12_LOG"
    _c12_since "$m"
}

# _c12_refused NAME: the probe failed (rc != 0) and printed no shell output
_c12_refused() {
    if [ "$C12_RC" != 0 ] && ! _c12_sub "$C12_OUT" 'uid='; then
        _c12_check "$1" 0
    else
        _c12_check "$1" 1 "rc=$C12_RC"
    fi
}
# _c12_no_uid NAME: no `id` output
_c12_no_uid() {
    if _c12_sub "$C12_OUT" 'uid='; then _c12_check "$1" 1 "uid in output"; else _c12_check "$1" 0; fi
}
# _c12_window NAME TEXT: in the open window the only reachable thing is the script (TEXT) or a refusal; no shell
_c12_window() {
    if _c12_sub "$C12_OUT" 'uid='; then
        _c12_check "$1" 1 "uid in output"
    elif _c12_sub "$C12_OUT" "$2" || _c12_sub "$C12_OUT" 'Permission denied' || { [ "$C12_RC" != 0 ] && [ -z "$C12_OUT" ]; }; then
        _c12_check "$1" 0
    else
        _c12_check "$1" 1 "rc=$C12_RC, no script message"
    fi
}
# _c12_msg NAME TEXT: the script printed TEXT
_c12_msg() {
    if _c12_sub "$C12_OUT" "$2"; then _c12_check "$1" 0; else _c12_check "$1" 1 "missing: $2"; fi
}

# _c12_pw_tool FILE TOOL args...: scp or sftp with the password from FILE (BatchMode=no, password only)
_c12_pw_tool() {
    local f=$1 tool=$2
    shift 2
    timeout 30 "${C12_CLIENT_ENV[@]}" sshpass -f "$f" "$tool" "${C12_OPTS[@]}" \
        -o BatchMode=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "$@"
}

# _c12_state_is NAME FIELD SHELL IN_GROUP(yes|no) ADMIN(present|absent): root's first-access state
_c12_state_is() {
    local name=$1 field=$2 shell=$3 grp=$4 adm=$5 got
    got=$(sp_exec sh -c 'printf "%s|%s|%s|%s\n" "$(getent shadow root | cut -d: -f2)" "$(getent passwd root | cut -d: -f7)" "$(id -nG root | tr " " "\n" | grep -qx unitotem-first-admin && echo yes || echo no)" "$(id -u admin >/dev/null 2>&1 && echo present || echo absent)"' 2>&1)
    _c12_log "state $name: $got"
    if [ "$got" = "$field|$shell|$grp|$adm" ]; then
        _c12_check "$name state" 0
    else
        _c12_check "$name state" 1 "got $got"
    fi
}

# _c12_effective NAME [window]: effective sshd settings for user root (sshd -T); usepam must match the config
_c12_effective() {
    local out
    out=$(sp_exec /usr/sbin/sshd -T -f "/etc/ssh/sshd_config.$C12_CFG" -C user=root,host=127.0.0.1,addr=127.0.0.1 2>&1 \
        | awk '/^(usepam|disableforwarding|permitemptypasswords|forcecommand|permitrootlogin|permittunnel|permituserrc|allowtcpforwarding|acceptenv) /')
    _c12_log "== $1 (sshd -T -C user=root)"
    printf '%s\n' "$out" | sed 's/^/effective: /' >> "$C12_LOG"
    if [ "$C12_CFG" = A ]; then
        _c12_line "$out" 'usepam no'; _c12_check "$1 usepam is off in A" $?
    else
        _c12_line "$out" 'usepam yes'; _c12_check "$1 usepam is on in B" $?
    fi
    if [ "${2:-}" = window ]; then
        _c12_line "$out" 'disableforwarding yes' && _c12_line "$out" 'permittunnel no' \
            && _c12_line "$out" 'permituserrc no' && _c12_line "$out" 'permitemptypasswords yes' \
            && _c12_line "$out" 'forcecommand /usr/sbin/unitotem-first-admin'
        _c12_check "$1 window: forwarding, tunnel, user rc off; empty password and script forced" $?
    fi
}

# _c12_fwd_start pw|key SPEC...: ssh -N in its own process group, bounded to 10 s; sets C12_FP
_c12_fwd_start() {
    local mode=$1
    shift
    if [ "$mode" = key ]; then
        setsid timeout -k 2 10 "${C12_CLIENT_ENV[@]}" ssh "${C12_OPTS[@]}" -o BatchMode=yes -i "$KEY_ROOT" \
            -o ExitOnForwardFailure=yes -p "$C12_PORT" -N "$@" root@127.0.0.1 >/dev/null 2>&1 &
    else
        setsid timeout -k 2 10 "${C12_CLIENT_ENV[@]}" sshpass -f "$PW_EMPTY" ssh "${C12_OPTS[@]}" \
            -o BatchMode=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
            -o ExitOnForwardFailure=yes -p "$C12_PORT" -N "$@" root@127.0.0.1 >/dev/null 2>&1 &
    fi
    C12_FP=$!
}
# _c12_fwd_stop: ends the forwarding client and its process group
_c12_fwd_stop() {
    kill -TERM -- "-$C12_FP" 2>/dev/null
    wait "$C12_FP" 2>/dev/null
}

# _c12_tcp_probe LPORT: waits (bounded) for a local listener, then reads the first bytes; sets C12_LISTEN, C12_BAN
_c12_tcp_probe() {
    local i
    C12_LISTEN=down
    for i in $(seq 1 10); do
        if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; then C12_LISTEN=up; break; fi
        sleep 0.3
    done
    C12_BAN=$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1; timeout 2 head -c 4 <&3" 2>/dev/null)
    _c12_log "tcp 127.0.0.1:$1 listener=$C12_LISTEN banner=${C12_BAN:-<none>}"
}

# _c12_socks_probe SPORT TARGET_PORT: SOCKS5 CONNECT 127.0.0.1:TARGET through the local -D listener; sets C12_SOCKS
_c12_socks_probe() {
    local i out
    for i in $(seq 1 10); do
        timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null && break
        sleep 0.3
    done
    out=$(python3 -I -c "$C12_SOCKS_PY" "$1" "$2" 2>&1)
    _c12_log "socks 127.0.0.1:$1 -> 127.0.0.1:$2:"
    printf '%s\n' "$out" | sed 's/^/socks: /' >> "$C12_LOG"
    C12_SOCKS="$out"
}

# _c12_listener_absent PORT NAME: no LISTEN socket on PORT in the container (hex PORT in /proc/net/tcp)
_c12_listener_absent() {
    local hex out
    hex=$(printf '%04X' "$1")
    out=$(sp_exec awk -v h=":$hex" '$4=="0A" && substr($2, length($2)-4) == h' /proc/net/tcp /proc/net/tcp6 2>&1)
    _c12_log "container listeners on $1: ${out:-none}"
    if [ -z "$out" ]; then _c12_check "$2" 0; else _c12_check "$2" 1 "listener present"; fi
}

# ---- cell 1: first access (root open) and nogroup -----------------------------------------------------------

# _c12_open TAG NOTTY_TEXT TTY_TEXT: every probe of the open window (root open, first-access script)
_c12_open() {
    local tag=$1 notty=$2 tty=$3 p dl
    p=$C12_PORT
    dl=$W/download-$tag.txt
    _c12_log "######## $tag open window"

    _c12_run "$tag P01 ssh root@127.0.0.1, no credentials (BatchMode=yes)" '' \
        sp_ssh "$C12_CFG" root@127.0.0.1 true
    _c12_window "$tag P01 no credentials: script message or refusal" "$notty"

    _c12_run "$tag P02 ssh -o PreferredAuthentications=none root@127.0.0.1" '' \
        sp_ssh "$C12_CFG" -o PreferredAuthentications=none root@127.0.0.1 true
    _c12_window "$tag P02 auth none: script message or refusal" "$notty"

    _c12_run "$tag P03 empty password (sshpass -f empty) ssh root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned'" '' \
        sp_sshpass "$C12_CFG" "$PW_EMPTY" root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned'
    _c12_window "$tag P03 empty password exec: script message, no shell" "$notty"

    _c12_run "$tag P04 ssh root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned' (BatchMode=yes)" '' \
        sp_ssh "$C12_CFG" root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned'
    _c12_window "$tag P04 batch exec: script message or refusal" "$notty"

    _c12_run "$tag P05 empty password, ssh -tt root@127.0.0.1 bash, stdin 'id'" $'id\n' \
        sp_sshpass "$C12_CFG" "$PW_EMPTY" -tt root@127.0.0.1 bash
    _c12_window "$tag P05 empty password tty: script prompt, no shell" "$tty"

    _c12_run "$tag P06 ssh -tt root@127.0.0.1 bash, BatchMode=yes, stdin EOF" '' \
        sp_ssh "$C12_CFG" -tt root@127.0.0.1 bash
    _c12_window "$tag P06 batch tty: script prompt or refusal" "$tty"

    _c12_run "$tag P07 sftp ls / (empty password)" $'ls /\n' \
        _c12_pw_tool "$PW_EMPTY" sftp -P "$p" -b - root@127.0.0.1
    _c12_refused "$tag P07 sftp refused"
    if _c12_line_any "$C12_OUT" bin etc usr var tmp; then
        _c12_check "$tag P07 no directory listing" 1 "listing"
    else
        _c12_check "$tag P07 no directory listing" 0
    fi

    _c12_run "$tag P08 scp upload to /tmp/sshd-pam-upload.txt (empty password)" '' \
        _c12_pw_tool "$PW_EMPTY" scp -P "$p" "$UP_FILE" root@127.0.0.1:/tmp/sshd-pam-upload.txt
    _c12_refused "$tag P08 scp upload refused"
    if sp_exec test -e /tmp/sshd-pam-upload.txt; then
        _c12_check "$tag P08 uploaded file absent in container" 1 "present"
    else
        _c12_check "$tag P08 uploaded file absent in container" 0
    fi

    _c12_run "$tag P09 scp download /etc/hostname (empty password)" '' \
        _c12_pw_tool "$PW_EMPTY" scp -P "$p" root@127.0.0.1:/etc/hostname "$dl"
    _c12_refused "$tag P09 scp download refused"
    if [ -e "$dl" ]; then _c12_check "$tag P09 downloaded file absent locally" 1 "present"; else _c12_check "$tag P09 downloaded file absent locally" 0; fi

    _c12_fwd_start pw -L 18080:127.0.0.1:2202
    _c12_tcp_probe 18080
    _c12_fwd_stop
    if [ "$C12_BAN" = "SSH-" ]; then _c12_check "$tag P10 -L 18080:127.0.0.1:2202 forwards" 1 "banner"; else _c12_check "$tag P10 -L forward refused" 0; fi

    _c12_fwd_start pw -D 11080
    _c12_socks_probe 11080 2202
    _c12_fwd_stop
    if _c12_sub "$C12_SOCKS" 'reply=00' || _c12_sub "$C12_SOCKS" 'banner=SSH-'; then
        _c12_check "$tag P11 -D 11080 SOCKS CONNECT" 1 "connected"
    else
        _c12_check "$tag P11 -D SOCKS CONNECT refused" 0
    fi

    _c12_run "$tag P12 -R 19999:127.0.0.1:22202 -o ExitOnForwardFailure=yes -N (empty password, 10 s)" '' \
        timeout -k 2 10 "${C12_CLIENT_ENV[@]}" sshpass -f "$PW_EMPTY" ssh "${C12_OPTS[@]}" \
        -o BatchMode=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
        -o ExitOnForwardFailure=yes -p "$p" -N -R 19999:127.0.0.1:22202 root@127.0.0.1
    _c12_listener_absent 19999 "$tag P12 no remote listener 19999 in container"

    _c12_run "$tag P13 -o Tunnel=point-to-point -w 0:0 -N (empty password, 30 s bound)" '' \
        sp_sshpass "$C12_CFG" "$PW_EMPTY" -o Tunnel=point-to-point -w 0:0 -N root@127.0.0.1
    _c12_log "P13 note: client-side tun open fails without root (not exercised server-side); config checked by sshd -T"
    if sp_exec test -e /sys/class/net/tun0; then _c12_check "$tag P13 no tun0 in container" 1 "tun0"; else _c12_check "$tag P13 no tun0 in container" 0; fi

    _c12_run "$tag P14 ssh -i id_other root@127.0.0.1 (key not installed)" '' \
        sp_ssh "$C12_CFG" -i "$KEY_OTHER" root@127.0.0.1 /bin/sh -c id
    _c12_refused "$tag P14 other key refused"

    _c12_run "$tag P15 wrong password (sshpass) root@127.0.0.1 /bin/sh -c id" '' \
        sp_sshpass "$C12_CFG" "$PW_WRONG" root@127.0.0.1 /bin/sh -c id
    _c12_refused "$tag P15 wrong password refused"

    _c12_run "$tag P16 installed root key id_root root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned' (no tty)" '' \
        sp_ssh "$C12_CFG" -i "$KEY_ROOT" root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned'
    _c12_no_uid "$tag P16 no id output"
    _c12_msg "$tag P16 script message (no tty)" "$notty"

    export LD_PRELOAD=/x
    _c12_run "$tag P17 LD_PRELOAD=/x in client env, SendEnv=*, id_root: env" '' \
        sp_ssh "$C12_CFG" -o SendEnv='*' -i "$KEY_ROOT" root@127.0.0.1 env
    unset LD_PRELOAD
    if _c12_linestart "$C12_OUT" 'LD_PRELOAD='; then
        _c12_check "$tag P17 LD_PRELOAD not passed" 1 "passed"
    else
        _c12_check "$tag P17 LD_PRELOAD not passed" 0
    fi
    _c12_msg "$tag P17 script message (no tty)" "$notty"

    if sp_exec test -e /tmp/pwned; then _c12_check "$tag no /tmp/pwned in container" 1 "present"; else _c12_check "$tag no /tmp/pwned in container" 0; fi
    _c12_effective "$tag" window
}

# _c12_nogroup TAG: root field empty, marker group removed; password and none must be refused
_c12_nogroup() {
    local tag=$1
    _c12_log "######## $tag root empty password, not in unitotem-first-admin"
    _c12_run "$tag N1 ssh root@127.0.0.1, no credentials (BatchMode=yes)" '' \
        sp_ssh "$C12_CFG" root@127.0.0.1 true
    _c12_refused "$tag N1 refused"
    _c12_run "$tag N2 ssh -o PreferredAuthentications=none root@127.0.0.1" '' \
        sp_ssh "$C12_CFG" -o PreferredAuthentications=none root@127.0.0.1 true
    _c12_refused "$tag N2 refused"
    _c12_run "$tag N3 empty password (sshpass -f empty) ssh root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned'" '' \
        sp_sshpass "$C12_CFG" "$PW_EMPTY" root@127.0.0.1 /bin/sh -c 'id; touch /tmp/pwned'
    _c12_refused "$tag N3 empty password refused"
    if sp_exec test -e /tmp/pwned; then _c12_check "$tag N3 no /tmp/pwned in container" 1 "present"; else _c12_check "$tag N3 no /tmp/pwned in container" 0; fi
}

# _c12_cell1: first access, open window (1a admin removed, 1b admin present), nogroup (1c)
_c12_cell1() {
    _c12_log "######## CELL 1 first access"
    if sp_exec id admin >/dev/null 2>&1; then
        sp_admin_remove >/dev/null 2>&1
    fi
    sp_set_root_state open >/dev/null 2>&1
    _c12_state_is "1a open, admin removed" "" /usr/sbin/unitotem-first-admin yes absent
    _c12_open 1a "First access: connect with an interactive terminal" "User name:"

    if sp_admin_make >/dev/null 2>&1; then
        _c12_check "1b create_first_admin (setup)" 0
    else
        _c12_check "1b create_first_admin (setup)" 1 "sp_admin_make"
    fi
    sp_set_root_state open >/dev/null 2>&1
    sp_keys_install >/dev/null 2>&1
    _c12_state_is "1b open, admin present" "" /usr/sbin/unitotem-first-admin yes present
    _c12_open 1b "Root accepts SSH keys only. Log in with an administrator account." "Root accepts SSH keys only. Log in with an administrator account."

    sp_set_root_state nogroup >/dev/null 2>&1
    _c12_state_is "1c nogroup, admin present" "" /usr/sbin/unitotem-first-admin no present
    _c12_nogroup "1c admin present"

    sp_admin_remove >/dev/null 2>&1
    _c12_state_is "1c nogroup, admin removed" "" /usr/sbin/unitotem-first-admin no absent
    _c12_nogroup "1c admin removed"
    _c12_effective "1c"
}

# ---- cell 2: root closed, then locked -----------------------------------------------------------------------

# _c12_cell2: root closed (password '*'): key login, password refused; then locked (usermod -L and field '!')
_c12_cell2() {
    _c12_log "######## CELL 2 closed and locked root"
    if ! sp_exec id admin >/dev/null 2>&1; then
        sp_admin_make >/dev/null 2>&1
    fi
    sp_set_root_state closed >/dev/null 2>&1
    sp_keys_install >/dev/null 2>&1
    _c12_state_is "2 closed" '*' /bin/bash no present

    _c12_run "2 K1 key login id_root: id -un" '' sp_ssh "$C12_CFG" -i "$KEY_ROOT" root@127.0.0.1 id -un
    if [ "$C12_RC" = 0 ] && [ "$C12_OUT" = root ]; then _c12_check "2 K1 key login gives a root shell" 0; else _c12_check "2 K1 key login gives a root shell" 1 "rc=$C12_RC out=$C12_OUT"; fi

    # Probe control: a direct connection to the sshd port must show its banner (forwards are refused by config)
    _c12_tcp_probe "$C12_PORT"
    if [ "$C12_BAN" = "SSH-" ]; then _c12_check "2 probe control: direct connection shows sshd banner" 0; else _c12_check "2 probe control: direct connection shows sshd banner" 1 "banner=$C12_BAN"; fi
    _c12_effective "2 closed"
    if _c12_line "$(sp_exec /usr/sbin/sshd -T -f "/etc/ssh/sshd_config.$C12_CFG" -C user=root,host=127.0.0.1,addr=127.0.0.1 2>&1)" 'allowtcpforwarding no'; then
        _c12_check "2 closed: allowtcpforwarding no for root (forwards refused by config)" 0
    else
        _c12_check "2 closed: allowtcpforwarding no for root (forwards refused by config)" 1 "not no"
    fi

    _c12_run "2 W1 wrong password" '' sp_sshpass "$C12_CFG" "$PW_WRONG" root@127.0.0.1 /bin/sh -c id
    _c12_refused "2 W1 wrong password refused"
    _c12_run "2 W2 empty password" '' sp_sshpass "$C12_CFG" "$PW_EMPTY" root@127.0.0.1 /bin/sh -c id
    _c12_refused "2 W2 empty password refused"
    _c12_run "2 W3 password '*'" '' sp_sshpass "$C12_CFG" "$PW_STAR" root@127.0.0.1 /bin/sh -c id
    _c12_refused "2 W3 password * refused"
    _c12_run "2 W4 auth none" '' sp_ssh "$C12_CFG" -o PreferredAuthentications=none root@127.0.0.1 id
    _c12_refused "2 W4 auth none refused"

    export LD_PRELOAD=/x
    _c12_run "2 E1 LD_PRELOAD=/x in client env, SendEnv=*, id_root: env" '' \
        sp_ssh "$C12_CFG" -o SendEnv='*' -i "$KEY_ROOT" root@127.0.0.1 env
    unset LD_PRELOAD
    if _c12_linestart "$C12_OUT" 'LD_PRELOAD='; then _c12_check "2 E1 LD_PRELOAD not accepted" 1 "accepted"; else _c12_check "2 E1 LD_PRELOAD not accepted" 0; fi

    sp_set_root_state locked >/dev/null 2>&1
    _c12_state_is "2 locked (usermod -L)" '!*' /bin/bash no present
    _c12_run "2 L1 key login id_root with field !*: id -un" '' sp_ssh "$C12_CFG" -i "$KEY_ROOT" root@127.0.0.1 id -un
    _rec lock_root_mu "$(_verdict "$C12_RC" "$C12_OUT" root)"

    sp_exec sh -c "sed -i 's/^root:[^:]*:/root:!:/' /etc/shadow"
    _c12_state_is "2 field exactly !" '!' /bin/bash no present
    _c12_run "2 L2 key login id_root with field !: id -un" '' sp_ssh "$C12_CFG" -i "$KEY_ROOT" root@127.0.0.1 id -un
    _rec lock_root_bang "$(_verdict "$C12_RC" "$C12_OUT" root)"

    sp_set_root_state closed >/dev/null 2>&1
    _c12_state_is "2 closed again (restore)" '*' /bin/bash no present
}

# _c12_default: the default state of the fixture (admin present, root closed, keys installed), verified
_c12_default() {
    _c12_log "######## restore default state"
    _c12_fresh
    if ! sp_up >/dev/null 2>&1; then _c12_check "restore sp_up" 1 "sp_up"; return 1; fi
    if ! sp_exec id admin >/dev/null 2>&1; then
        if ! sp_admin_make >/dev/null 2>&1; then _c12_check "restore admin" 1 "create_first_admin"; return 1; fi
    fi
    sp_set_root_state closed >/dev/null 2>&1
    sp_keys_install >/dev/null 2>&1
    _c12_state_is "restore default" '*' /bin/bash no present
    _c12_run "restore: admin key login id -un" '' sp_ssh "$C12_CFG" -i "$KEY_ADMIN" admin@127.0.0.1 id -un
    if [ "$C12_OUT" = admin ]; then _c12_check "restore admin key login" 0; else _c12_check "restore admin key login" 1 "out=$C12_OUT"; fi
}

# _c12_cleanup: container test files of this config (literal container paths)
_c12_cleanup() {
    sp_exec rm -f -- /tmp/pwned /tmp/sshd-pam-upload.txt
}

# ---- cells 3-6 ----------------------------------------------------------------------------------------------

# _c3_run NAME STDIN CMD...: runs CMD with STDIN piped in on fresh listeners. Sets C3_OUT (stdout), C3_ERRTXT
# (stderr), C3_RC, C3_LOGTXT (sshd log lines added by this probe). Logs all of them.
_c3_run() {
    local name=$1 input=$2 m
    shift 2
    _c12_fresh
    m=$(_c12_mark)
    C3_OUT=$(printf '%s' "$input" | "$@" 2>"$ERRF")
    C3_RC=$?
    C3_ERRTXT=$(cat "$ERRF")
    C3_LOGTXT=$(sp_exec sh -c 'tail -n +"$2" "$1"' sh "/var/log/sshd-$C12_CFG.log" "$((m + 1))" 2>/dev/null)
    _c12_log "== $name"
    _c12_log "stdin: ${input:-<none>}"
    _c12_log "rc: $C3_RC"
    printf '%s\n' "$C3_OUT" | head -n 12 | cut -c1-240 | sed 's/^/out: /' >> "$C12_LOG"
    printf '%s\n' "$C3_ERRTXT" | head -n 12 | cut -c1-240 | sed 's/^/err: /' >> "$C12_LOG"
    printf '%s\n' "$C3_LOGTXT" | head -n 20 | cut -c1-240 | sed 's/^/sshd-log: /' >> "$C12_LOG"
}

# _c3_ok NAME WANT: the probe exited 0 and its stdout is exactly WANT
_c3_ok() {
    if [ "$C3_RC" = 0 ] && [ "$C3_OUT" = "$2" ]; then
        _c12_check "$1" 0
    else
        _c12_check "$1" 1 "rc=$C3_RC out=$C3_OUT err=$C3_ERRTXT"
    fi
}

# _c3_refused NAME: the probe exited non-zero and printed no `admin` / `root` identity line
_c3_refused() {
    if [ "$C3_RC" != 0 ] && [ "$C3_OUT" != admin ] && [ "$C3_OUT" != root ]; then
        _c12_check "$1" 0
    else
        _c12_check "$1" 1 "rc=$C3_RC out=$C3_OUT"
    fi
}

# _c3_dbg_offers KEYARGS...: ssh as admin with the given -i keys only, publickey only, LogLevel=DEBUG1
_c3_dbg_offers() {
    timeout 30 env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
        ssh -F /dev/null -o IdentityAgent=none -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=DEBUG1 \
        -o PreferredAuthentications=publickey -p "$(sp_port "$C12_CFG")" "$@" admin@127.0.0.1 id -un
}

# _c3_shadow FIELD: field of admin's shadow entry in the container (2 = hash, 3 = last change, 8 = expiry)
_c3_shadow() {
    sp_exec sh -c 'getent shadow admin | cut -d: -f"$1"' sh "$1" 2>/dev/null
}

# ---- cell 3: administrator ----------------------------------------------------------------------------------

_c3_admin() {
    local cfg=$C12_CFG orig_days iso k noffer nmax nclient orig_exp lockhash_before
    local a=()
    _c12_log "######## CELL 3 administrator ($cfg)"

    _c3_run "3.1 password login admin, id -un (correct password)" '' sp_sshpass "$cfg" "$PW_ADMIN" admin@127.0.0.1 id -un
    _c3_ok "3.1 correct password logs in as admin" admin

    _c3_run "3.2 password login admin, id -un (wrong password)" '' sp_sshpass "$cfg" "$PW_WRONG" admin@127.0.0.1 id -un
    _c3_refused "3.2 wrong password refused"

    _c3_run "3.3 key login admin, id -un (id_admin)" '' sp_ssh "$cfg" -i "$KEY_ADMIN" admin@127.0.0.1 id -un
    _c3_ok "3.3 key login ok" admin

    # 3.4-3.6 locked account (usermod -L prefixes the hash with '!'): password refused; key result is info (3.5)
    lockhash_before=$(_c3_shadow 2)
    sp_exec usermod -L admin >/dev/null 2>&1
    _c12_log "3.4 admin hash while locked: $(_c3_shadow 2)"
    _c3_run "3.4 locked: password login admin (correct password)" '' sp_sshpass "$cfg" "$PW_ADMIN" admin@127.0.0.1 id -un
    _c3_refused "3.4 locked: password refused"
    _c3_run "3.5 locked: key login admin (id_admin)" '' sp_ssh "$cfg" -i "$KEY_ADMIN" admin@127.0.0.1 id -un
    _rec lock_admin "$(_verdict "$C3_RC" "$C3_OUT" admin)"
    case "$(_c3_shadow 2)" in
        '!'*) sp_exec usermod -U admin >/dev/null 2>&1 ;;
    esac
    if [ "$(_c3_shadow 2)" = "$lockhash_before" ]; then
        _c12_check "3.6 unlocked: hash identical to before the lock" 0
    else
        _c12_check "3.6 unlocked: hash identical to before the lock" 1 "hash differs"
    fi

    # 3.7 MaxAuthTries 5: six wrong keys offered, publickey only (the client gives up after six identities)
    for k in "${WKEYS[@]}"; do
        [ -s "$k" ] || ssh-keygen -q -t ed25519 -N '' -C sshd-pam-test -f "$k" >/dev/null 2>&1 || { _c12_check "3.7 make wrong keys" 1 "ssh-keygen"; return 1; }
    done
    for k in "${WKEYS[@]}"; do a+=(-i "$k"); done
    _c3_run "3.7 MaxAuthTries: six wrong keys, publickey only (client debug1)" '' _c3_dbg_offers "${a[@]}"
    _c3_refused "3.7 six wrong keys refused"
    noffer=$(_c3_count "$C3_ERRTXT" 'Offering public key:')
    nmax=$(_c3_count "$C3_LOGTXT" 'maximum authentication attempts exceeded for admin')
    nclient=$(_c3_count "$C3_ERRTXT" 'Too many authentication failures')
    _info "3.7 $cfg client 'Offering public key' lines=$noffer; sshd 'maximum authentication attempts exceeded' lines=$nmax; client 'Too many authentication failures' lines=$nclient"
    if [ "$nmax" -ge 1 ] && [ "$nclient" -ge 1 ] && [ "$noffer" -ge 1 ] && [ "$noffer" -le 6 ]; then
        _c12_check "3.7 MaxAuthTries 5: sshd disconnects with Too many authentication failures" 0
    else
        _c12_check "3.7 MaxAuthTries 5: sshd disconnects with Too many authentication failures" 1 "offers=$noffer sshd=$nmax client=$nclient"
    fi

    # 3.8-3.10 expired password (chage -d 0): password refused; key result is info; last-change day restored
    orig_days=$(_c3_shadow 3)
    iso=$(date -u -d "@$((orig_days * 86400))" +%F)
    sp_exec chage -d 0 admin >/dev/null 2>&1
    _c12_log "3.8 chage -l admin after chage -d 0:"
    sp_exec chage -l admin | sed 's/^/chage: /' >> "$C12_LOG"
    _c3_run "3.8 expired (chage -d 0): password login admin" '' sp_sshpass "$cfg" "$PW_ADMIN" admin@127.0.0.1 id -un
    _c3_refused "3.8 expired: password login refused"
    _rec exp_pw "$(_verdict "$C3_RC" "$C3_OUT" admin)"
    _c3_run "3.9 expired (chage -d 0): key login admin" '' sp_ssh "$cfg" -i "$KEY_ADMIN" admin@127.0.0.1 id -un
    _rec exp_key "$(_verdict "$C3_RC" "$C3_OUT" admin)"
    sp_exec chage -d "$iso" admin >/dev/null 2>&1
    if [ "$(_c3_shadow 3)" = "$orig_days" ]; then
        _c12_check "3.10 expiry restored: last change day unchanged" 0
    else
        _c12_check "3.10 expiry restored: last change day unchanged" 1 "was $orig_days now $(_c3_shadow 3)"
    fi
    if [ "$(sp_exec chage -l admin | sed -n 's/^Password expires[[:space:]]*: //p')" = never ]; then
        _c12_check "3.10 chage -l: password expires never (as before)" 0
    else
        _c12_check "3.10 chage -l: password expires never (as before)" 1 "not never"
    fi
    _c12_log "3.10 chage -l admin after restore:"
    sp_exec chage -l admin | sed 's/^/chage: /' >> "$C12_LOG"

    # 3.11-3.13 account expiry (usermod -e 1): measured fresh, recorded as info; expiry restored
    orig_exp=$(_c3_shadow 8)
    sp_exec usermod -e 1 admin >/dev/null 2>&1
    _c3_run "3.11 account expired (usermod -e 1): password login admin" '' sp_sshpass "$cfg" "$PW_ADMIN" admin@127.0.0.1 id -un
    _rec acct_pw "$(_verdict "$C3_RC" "$C3_OUT" admin)"
    _c3_run "3.12 account expired (usermod -e 1): key login admin" '' sp_ssh "$cfg" -i "$KEY_ADMIN" admin@127.0.0.1 id -un
    _rec acct_key "$(_verdict "$C3_RC" "$C3_OUT" admin)"
    if [ -z "$orig_exp" ]; then
        sp_exec usermod -e '' admin >/dev/null 2>&1
    else
        sp_exec usermod -e "$(date -u -d "@$((orig_exp * 86400))" +%F)" admin >/dev/null 2>&1
    fi
    if [ "$(_c3_shadow 8)" = "$orig_exp" ]; then
        _c12_check "3.13 account expiry restored" 0
    else
        _c12_check "3.13 account expiry restored" 1 "was [$orig_exp] now [$(_c3_shadow 8)]"
    fi
}

# ---- cell 4: MOTD and transfers -----------------------------------------------------------------------------

# _c4_xfer NAME CMD...: runs a transfer, sets C4_RC and C4_ERRTXT, logs rc and first stderr lines
_c4_xfer() {
    local name=$1
    shift
    _c12_fresh
    "$@" 2>"$ERRF"
    C4_RC=$?
    C4_ERRTXT=$(cat "$ERRF")
    _c12_log "== $name"
    _c12_log "rc: $C4_RC"
    head -n 5 "$ERRF" | cut -c1-240 | sed 's/^/err: /' >> "$C12_LOG"
}

_c4_scp() { timeout 60 env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
    scp "${C4_OPTS[@]}" -i "$KEY_ADMIN" -P "$(sp_port "$C12_CFG")" "$@"; }
_c4_scpO() { timeout 60 env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
    scp -O "${C4_OPTS[@]}" -i "$KEY_ADMIN" -P "$(sp_port "$C12_CFG")" "$@"; }
_c4_sftpb() { timeout 60 env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
    sftp "${C4_OPTS[@]}" -i "$KEY_ADMIN" -P "$(sp_port "$C12_CFG")" -b "$1" admin@127.0.0.1; }
_c4_rsync() { timeout 60 env -u DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
    rsync -e "ssh ${C4_OPTS[*]} -i $KEY_ADMIN -p $(sp_port "$C12_CFG")" "$@"; }
_c4_cat() { sp_ssh "$C12_CFG" -i "$KEY_ADMIN" admin@127.0.0.1 cat "$1" > "$2"; }
_c4_bare() { sp_ssh "$C12_CFG" -i "$KEY_ADMIN" admin@127.0.0.1 printf abc > "$BARE"; }

# _c4_rsha PATH: sha256 of a container file as admin (sets C4_RSHA; empty when the file is missing)
_c4_rsha() {
    local out
    out=$(sp_ssh "$C12_CFG" -i "$KEY_ADMIN" admin@127.0.0.1 sha256sum "$1" 2>&1)
    C4_RSHA=""
    read -r C4_RSHA _ <<<"$out"
    _c12_log "remote sha256 $1: ${C4_RSHA:-none}"
}

# _c4_timed NAME FN: five runs of FN, wall seconds per run and mean; info only
_c4_timed() {
    local name=$1 fn=$2 i t0 t1 rc d list="" rcs="" mean
    _c12_fresh
    for i in 1 2 3 4 5; do
        t0=$(date +%s.%N)
        "$fn" >/dev/null 2>&1
        rc=$?
        t1=$(date +%s.%N)
        d=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
        list="$list $d"
        rcs="$rcs$rc,"
        _c12_log "$name run $i rc=$rc wall=${d}s"
    done
    mean=$(printf '%s\n' $list | awk '{s+=$1} END{printf "%.3f", s/NR}')
    _info "$name wall s:$list mean=$mean rc=$rcs"
}
_c4_t_cmd() { sp_ssh "$C12_CFG" -i "$KEY_ADMIN" admin@127.0.0.1 true; }
_c4_t_inter() { printf 'exit\n' | sp_ssh "$C12_CFG" -tt -i "$KEY_ADMIN" admin@127.0.0.1; }

_c4_motd() {
    local cfg=$C12_CFG has want i list="" d mean rc allok s e out subsys
    local d_scp=$W/dl-scp.bin d_cat=$W/dl-cat.bin d_sftp=$W/dl-sftp.bin d_rsync=$W/dl-rsync.bin
    local sftp_all=1
    _c12_log "######## CELL 4 MOTD and transfers ($cfg)"

    _c3_run "4.1 interactive login, ssh -tt admin (stdin: exit)" $'exit\n' sp_ssh "$cfg" -tt -i "$KEY_ADMIN" admin@127.0.0.1
    C4_OUT_INTER=$C3_OUT
    C4_ERR_INTER=$C3_ERRTXT
    if _c12_sub "$C3_OUT" "$C6_HDR"; then has=yes; else has=no; fi
    if [ "$cfg" = B ]; then want=yes; else want=no; fi
    _info "4.1 $cfg interactive login rc=$C3_RC, header present=$has"
    if [ "$C3_RC" = 0 ] && [ "$has" = "$want" ]; then
        _c12_check "4.1 MOTD header in interactive login: $([ "$want" = yes ] && echo present || echo absent) in $cfg" 0
    else
        _c12_check "4.1 MOTD header in interactive login: $([ "$want" = yes ] && echo present || echo absent) in $cfg" 1 "rc=$C3_RC present=$has"
    fi

    _c3_run "4.2 command login, ssh admin true" '' sp_ssh "$cfg" -i "$KEY_ADMIN" admin@127.0.0.1 true
    C4_ERR_CMD=$C3_ERRTXT
    if [ "$C3_RC" = 0 ] && [ -z "$C3_OUT" ]; then _c12_check "4.2 command login prints nothing" 0; else _c12_check "4.2 command login prints nothing" 1 "rc=$C3_RC out=$C3_OUT"; fi

    _c3_run "4.3 ssh -T admin true (no tty)" '' sp_ssh "$cfg" -T -i "$KEY_ADMIN" admin@127.0.0.1 true
    if [ "$C3_RC" = 0 ] && [ -z "$C3_OUT" ]; then _c12_check "4.3 ssh -T prints nothing" 0; else _c12_check "4.3 ssh -T prints nothing" 1 "rc=$C3_RC out=$C3_OUT"; fi

    _c4_xfer "4.4 bare output: ssh admin 'printf abc' to file" _c4_bare
    printf abc > "$EXP_ABC"
    if [ "$C4_RC" = 0 ] && cmp -s "$BARE" "$EXP_ABC"; then
        _c12_check "4.4 shell command output is exactly abc" 0
    else
        _c12_check "4.4 shell command output is exactly abc" 1 "rc=$C4_RC size=$(wc -c < "$BARE" 2>/dev/null)"
    fi

    # 4.5 transfers: 1 MiB random file, every path must reproduce the bytes exactly
    head -c 1048576 /dev/urandom > "$BIN" || { _c12_check "4.5 make 1 MiB file" 1 "urandom"; return 1; }
    read -r C4_LSHA _ < <(sha256sum "$BIN")
    _c12_log "local sha256 $BIN: $C4_LSHA"

    _c4_xfer "4.5a scp -O (legacy SCP protocol) upload 1 MiB to /home/admin/sshd-pam-scp-up.bin" \
        _c4_scpO "$BIN" "admin@127.0.0.1:/home/admin/sshd-pam-scp-up.bin"
    _c4_rsha /home/admin/sshd-pam-scp-up.bin
    if [ "$C4_RC" = 0 ] && [ "$C4_RSHA" = "$C4_LSHA" ]; then _c12_check "4.5a scp -O upload bytes unchanged" 0; else _c12_check "4.5a scp -O upload bytes unchanged" 1 "rc=$C4_RC"; fi

    _c4_xfer "4.5b scp -O download /home/admin/sshd-pam-scp-up.bin" \
        _c4_scpO "admin@127.0.0.1:/home/admin/sshd-pam-scp-up.bin" "$d_scp"
    if [ "$C4_RC" = 0 ] && cmp -s "$BIN" "$d_scp"; then _c12_check "4.5b scp -O download bytes unchanged (cmp)" 0; else _c12_check "4.5b scp -O download bytes unchanged (cmp)" 1 "rc=$C4_RC"; fi

    # SFTP subsystem: default scp/sftp modes are recorded as info (see the cross-config lines), not asserted
    _c4_xfer "4.5c scp (default, SFTP mode) upload to /home/admin/sshd-pam-scp-default.bin" \
        _c4_scp "$BIN" "admin@127.0.0.1:/home/admin/sshd-pam-scp-default.bin"
    _c4_rsha /home/admin/sshd-pam-scp-default.bin
    if [ "$C4_RC" != 0 ] && _c12_sub "$C4_ERRTXT" 'subsystem request failed' && [ "$C4_RSHA" != "$C4_LSHA" ]; then :; else sftp_all=0; fi
    _info "4.5c $cfg scp default mode rc=$C4_RC bytes ok=$([ "$C4_RSHA" = "$C4_LSHA" ] && echo yes || echo no)"

    _c4_xfer "4.5d ssh admin cat /home/admin/sshd-pam-scp-up.bin > file" _c4_cat /home/admin/sshd-pam-scp-up.bin "$d_cat"
    if [ "$C4_RC" = 0 ] && cmp -s "$BIN" "$d_cat"; then _c12_check "4.5d ssh cat bytes unchanged (cmp)" 0; else _c12_check "4.5d ssh cat bytes unchanged (cmp)" 1 "rc=$C4_RC"; fi

    printf 'put %s /home/admin/sshd-pam-sftp-up.bin\n' "$BIN" > "$BATCH"
    _c4_xfer "4.5e sftp put to /home/admin/sshd-pam-sftp-up.bin (batch file)" _c4_sftpb "$BATCH"
    _c4_rsha /home/admin/sshd-pam-sftp-up.bin
    if [ "$C4_RC" != 0 ] && _c12_sub "$C4_ERRTXT" 'subsystem request failed'; then :; else sftp_all=0; fi
    _info "4.5e $cfg sftp put rc=$C4_RC bytes ok=$([ "$C4_RSHA" = "$C4_LSHA" ] && echo yes || echo no)"

    printf 'get /home/admin/sshd-pam-scp-up.bin %s\n' "$d_sftp" > "$BATCH"
    _c4_xfer "4.5f sftp get /home/admin/sshd-pam-scp-up.bin (batch file)" _c4_sftpb "$BATCH"
    if [ "$C4_RC" != 0 ] && _c12_sub "$C4_ERRTXT" 'subsystem request failed'; then :; else sftp_all=0; fi
    _info "4.5f $cfg sftp get rc=$C4_RC"

    _c4_xfer "4.5g rsync -e ssh upload to /home/admin/sshd-pam-rsync-up.bin" \
        _c4_rsync "$BIN" "admin@127.0.0.1:/home/admin/sshd-pam-rsync-up.bin"
    _c4_rsha /home/admin/sshd-pam-rsync-up.bin
    if [ "$C4_RC" = 0 ] && [ "$C4_RSHA" = "$C4_LSHA" ]; then _c12_check "4.5g rsync upload bytes unchanged" 0; else _c12_check "4.5g rsync upload bytes unchanged" 1 "rc=$C4_RC"; fi

    _c4_xfer "4.5h rsync -e ssh download /home/admin/sshd-pam-scp-up.bin" \
        _c4_rsync "admin@127.0.0.1:/home/admin/sshd-pam-scp-up.bin" "$d_rsync"
    if [ "$C4_RC" = 0 ] && cmp -s "$BIN" "$d_rsync"; then _c12_check "4.5h rsync download bytes unchanged (cmp)" 0; else _c12_check "4.5h rsync download bytes unchanged (cmp)" 1 "rc=$C4_RC"; fi

    # subsystem state for the cross-config line: no Subsystem in sshd -T and the default transfers refused by it
    subsys=$(sp_exec /usr/sbin/sshd -T -f "/etc/ssh/sshd_config.$cfg" 2>/dev/null | awk '/^subsystem /{print}')
    if [ -z "$subsys" ] && [ "$sftp_all" = 1 ]; then
        _rec sftp absent
    else
        _rec sftp "other (sshd -T subsystem: ${subsys:-none})"
    fi

    # 4.6 login wall time (key login, command and interactive), five runs each: info only
    _c4_timed "4.6 $cfg login wall time, ssh admin true" _c4_t_cmd
    _c4_timed "4.6 $cfg login wall time, ssh -tt admin (exit)" _c4_t_inter

    # 4.7 script run time inside the container: python3 -I /usr/share/unitotem/unitotem-motd, five runs
    out=$(sp_exec sh -c 'i=0; while [ $i -lt 5 ]; do s=$(date +%s.%N); python3 -I /usr/share/unitotem/unitotem-motd >/dev/null 2>&1; rc=$?; e=$(date +%s.%N); echo "$s $e $rc"; i=$((i+1)); done' 2>&1)
    list=""
    allok=1
    while read -r s e rc; do
        d=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", b-a}')
        list="$list $d"
        [ "$rc" = 0 ] || allok=0
        _c12_log "unitotem-motd run rc=$rc wall=${d}s"
    done <<<"$out"
    mean=$(printf '%s\n' $list | awk '{s+=$1} END{printf "%.3f", s/NR}')
    _info "4.7 $cfg python3 -I unitotem-motd in container wall s:$list mean=$mean"
    if [ "$allok" = 1 ]; then _c12_check "4.7 unitotem-motd runs exit 0" 0; else _c12_check "4.7 unitotem-motd runs exit 0" 1 "rc not 0"; fi
    _info "4.8 $cfg pam_ lines in sshd-$cfg.log: $(sp_exec sh -c "grep -c pam_ /var/log/sshd-$cfg.log; true" 2>/dev/null | tr -d ' \n')"
}

# ---- cell 5: side effects of UsePAM yes ---------------------------------------------------------------------

_c5_client_it() { ( export LANG=it_IT.UTF-8; sp_ssh "$C12_CFG" -o SendEnv=LANG -i "$KEY_ADMIN" admin@127.0.0.1 'echo $LANG' ); }
_c5_env() { sp_ssh "$C12_CFG" -i "$KEY_ADMIN" admin@127.0.0.1 'ulimit -a; env | sort'; }

_c5_side() {
    local cfg=$C12_CFG
    _c12_log "######## CELL 5 side effects ($cfg)"
    _c3_run "5.1 SetEnv LANG: ssh admin 'echo \$LANG' (no client LANG)" '' sp_ssh "$cfg" -i "$KEY_ADMIN" admin@127.0.0.1 'echo $LANG'
    _c3_ok "5.1 LANG is en_US.UTF-8" en_US.UTF-8

    _c3_run "5.2 client LANG=it_IT.UTF-8 with SendEnv=LANG" '' _c5_client_it
    _c3_ok "5.2 client LANG ignored, en_US.UTF-8 kept" en_US.UTF-8

    _c3_run "5.3 ssh admin 'ulimit -a; env | sort'" '' _c5_env
    printf '%s\n' "$C3_OUT" > "$W/env-$cfg.txt"
    if [ "$C3_RC" = 0 ]; then _c12_check "5.3 env and ulimit collected" 0; else _c12_check "5.3 env and ulimit collected" 1 "rc=$C3_RC"; fi

    # 5.4 stderr of the interactive and command logins (captured separately) has no pam_ text
    if _c12_sub "$C4_ERR_INTER" pam_; then
        _c12_check "5.4 interactive stderr has no pam_ text" 1 "pam_ text"
    else
        _c12_check "5.4 interactive stderr has no pam_ text" 0
    fi
    if _c12_sub "$C4_ERR_CMD" pam_; then
        _c12_check "5.4 command stderr has no pam_ text" 1 "pam_ text"
    else
        _c12_check "5.4 command stderr has no pam_ text" 0
    fi

    # 5.5 /etc/nologin: admin refused (password and key), root key still accepted; the client text is info
    sp_exec sh -c 'echo closed > /etc/nologin'
    _c3_run "5.5a /etc/nologin: admin password login" '' sp_sshpass "$cfg" "$PW_ADMIN" admin@127.0.0.1 id -un
    _c3_refused "5.5a admin password refused under nologin"
    _rec nologin "refused rc=$C3_RC client text=[$(printf '%s %s' "$C3_OUT" "$C3_ERRTXT" | tr '\n' ' ' | sed 's/ *$//')]"
    _c3_run "5.5b /etc/nologin: admin key login" '' sp_ssh "$cfg" -i "$KEY_ADMIN" admin@127.0.0.1 id -un
    _c3_refused "5.5b admin key refused under nologin"
    _c3_run "5.5c /etc/nologin: root key login (id_root)" '' sp_ssh "$cfg" -i "$KEY_ROOT" root@127.0.0.1 id -un
    _c3_ok "5.5c root key accepted under nologin" root
    sp_exec rm -f -- /etc/nologin
    if sp_exec test -e /etc/nologin; then _c12_check "5.5d /etc/nologin removed" 1 "present"; else _c12_check "5.5d /etc/nologin removed" 0; fi
}

# ---- cell 6: Match block (sshd -T) --------------------------------------------------------------------------

# _c6_eff CFG CONTEXT FILE: sshd -T for CONTEXT with config CFG (inside the container), saved to FILE
_c6_eff() {
    sp_exec /usr/sbin/sshd -T -C "$2" -f "/etc/ssh/sshd_config.$1" > "$3" 2>&1
}

_c6_match() {
    local cfg=$C12_CFG f out up
    _c12_log "######## CELL 6 Match ($cfg)"
    if [ "$cfg" = A ]; then up=no; else up=yes; fi
    f=$W/t-$cfg-root.txt
    _c6_eff "$cfg" user=root,host=localhost,addr=127.0.0.1 "$f"
    out=$(cat "$f")
    _c12_log "== sshd -T -C user=root,host=localhost,addr=127.0.0.1 -f sshd_config.$cfg"
    printf '%s\n' "$out" | sed 's/^/eff: /' >> "$C12_LOG"
    if _c12_line "$out" 'permitrootlogin without-password' && _c12_line "$out" 'permitemptypasswords no' \
        && _c12_line "$out" 'forcecommand none' && _c12_line "$out" "usepam $up"; then
        _c12_check "6 $cfg root outside the group: prohibit-password, permitemptypasswords no, forcecommand none, usepam $up" 0
    else
        _c12_check "6 $cfg root outside the group: prohibit-password, permitemptypasswords no, forcecommand none, usepam $up" 1 "see $f"
    fi

    f=$W/t-$cfg-admin.txt
    _c6_eff "$cfg" user=admin,host=localhost,addr=127.0.0.1 "$f"
    out=$(cat "$f")
    _c12_log "== sshd -T -C user=admin,host=localhost,addr=127.0.0.1 -f sshd_config.$cfg"
    printf '%s\n' "$out" | sed 's/^/eff: /' >> "$C12_LOG"
    if _c12_line "$out" 'forcecommand none' && _c12_line "$out" "usepam $up"; then
        _c12_check "6 $cfg admin: forcecommand none, usepam $up" 0
    else
        _c12_check "6 $cfg admin: forcecommand none, usepam $up" 1 "see $f"
    fi

    # sshd -T -C group= is rejected by this build: recorded as info, the group case is covered by cells 1 and 2
    f=$W/t-$cfg-group.txt
    _c6_eff "$cfg" user=root,group=unitotem-first-admin,host=localhost,addr=127.0.0.1 "$f"
    _c12_log "== sshd -T -C user=root,group=unitotem-first-admin,host=localhost,addr=127.0.0.1 -f sshd_config.$cfg"
    sed 's/^/eff: /' "$f" >> "$C12_LOG"
    _info "6 $cfg sshd -T -C group= not supported by this build: $(head -n 1 "$f")"
}

# sp_cell6_diff: sshd -T of A and B for root and admin (no group); the only difference allowed is usepam
sp_cell6_diff() {
    local ctx name fa fb d l changed
    for ctx in user=root,host=localhost,addr=127.0.0.1 user=admin,host=localhost,addr=127.0.0.1; do
        name=$(printf '%s' "$ctx" | tr ',=' '__')
        fa=$W/diff-A-$name.txt
        fb=$W/diff-B-$name.txt
        _c6_eff A "$ctx" "$fa"
        _c6_eff B "$ctx" "$fb"
        d=$(diff "$fa" "$fb")
        changed=""
        while IFS= read -r l; do
            case $l in
                '<'*|'>'*) changed="$changed$l;" ;;
            esac
        done <<<"$d"
        if [ "$changed" = "< usepam no;> usepam yes;" ]; then
            _c12_check "6 diff A vs B ($ctx): only usepam differs" 0
        else
            _c12_check "6 diff A vs B ($ctx): only usepam differs" 1 "changed: $changed"
        fi
    done
}

# ---- restore, cross-config info and driver -----------------------------------------------------------------

# _c3_restore: admin unlocked with its original hash, /etc/nologin gone, default state checked
_c3_restore() {
    _c12_log "######## restore default state ($C12_CFG)"
    case "$(_c3_shadow 2)" in
        '!'*) sp_exec usermod -U admin >/dev/null 2>&1 ;;
    esac
    sp_exec rm -f -- /etc/nologin
    if [ "$(_c3_shadow 2)" = "$C3_HASH0" ]; then _c12_check "restore admin hash as at start" 0; else _c12_check "restore admin hash as at start" 1 "differs"; fi
    if sp_exec test -e /etc/nologin; then _c12_check "restore /etc/nologin absent" 1 "present"; else _c12_check "restore /etc/nologin absent" 0; fi
    _c12_state_is "restore default" '*' /bin/bash no present
    _c3_run "restore: admin key login id -un" '' sp_ssh "$C12_CFG" -i "$KEY_ADMIN" admin@127.0.0.1 id -un
    _c3_ok "restore admin key login" admin
}

# _c3_cleanup: container files of this config (literal container paths)
_c3_cleanup() {
    sp_exec rm -f -- /home/admin/sshd-pam-scp-up.bin /home/admin/sshd-pam-scp-default.bin \
        /home/admin/sshd-pam-sftp-up.bin /home/admin/sshd-pam-rsync-up.bin
}

# run_cfg A|B: cells 1 to 6 for one config, then the default-state restore
run_cfg() {
    C12_CFG=$1
    C12_PORT=$(sp_port "$C12_CFG") || return 1
    C12_LOG=$W/log-$C12_CFG.log
    : > "$C12_LOG"
    if ! sp_up >/dev/null 2>&1; then _c12_check "sp_up config $C12_CFG" 1 "ports did not answer"; return 1; fi
    if ! sp_exec id admin >/dev/null 2>&1; then
        if ! sp_admin_make >/dev/null 2>&1; then _c12_check "setup admin" 1 "create_first_admin failed"; return 1; fi
    fi
    if ! sp_keys_install >/dev/null 2>&1; then _c12_check "setup keys" 1 "sp_keys_install"; return 1; fi

    _c12_cell1
    _c12_cell2
    _c12_default
    _c12_cleanup

    C3_HASH0=$(_c3_shadow 2)
    _c12_log "admin hash at start: $C3_HASH0"
    _c3_admin
    _c4_motd
    _c5_side
    _c6_match
    _c3_restore
    _c3_cleanup
    _c12_cleanup
    return 0
}

# cross_env: A vs B `ulimit -a; env | sort`. Only SSH_CLIENT and SSH_CONNECTION (per connection) may differ, and the
# known PAM side effects are info; any other changed line fails.
cross_env() {
    local d l n=0 unexpected=0 core_a core_b motd_a motd_b mail_a mail_b
    C12_CFG=""
    if [ ! -s "$W/env-A.txt" ] || [ ! -s "$W/env-B.txt" ]; then
        _c12_check "5 env A vs B: both configs collected" 1 "missing"
        return 0
    fi
    d=$(diff "$W/env-A.txt" "$W/env-B.txt")
    while IFS= read -r l; do
        case $l in
            '<'*|'>'*) n=$((n + 1)) ;;
            *) continue ;;
        esac
        case $l in
            *SSH_CLIENT=*|*SSH_CONNECTION=*) ;;
            *'core file size'*|*MOTD_SHOWN=*|*MAIL=*) ;;
            *) unexpected=$((unexpected + 1)) ;;
        esac
    done <<<"$d"
    core_a=$(awk '/core file size/{print $NF}' "$W/env-A.txt")
    core_b=$(awk '/core file size/{print $NF}' "$W/env-B.txt")
    motd_a=$(awk -F= '/^MOTD_SHOWN=/{print $2}' "$W/env-A.txt")
    motd_b=$(awk -F= '/^MOTD_SHOWN=/{print $2}' "$W/env-B.txt")
    mail_a=$(awk -F= '/^MAIL=/{print $2}' "$W/env-A.txt")
    mail_b=$(awk -F= '/^MAIL=/{print $2}' "$W/env-B.txt")
    _info "5 PAM limits A vs B: core file size soft limit A=${core_a:-absent} B=${core_b:-absent}"
    _info "5 PAM env A vs B: MOTD_SHOWN A=${motd_a:-absent} B=${motd_b:-absent}; MAIL A=${mail_a:-absent} B=${mail_b:-absent}"
    if [ "$unexpected" = 0 ]; then
        _c12_check "5 env/ulimit A vs B: no difference other than SSH_CLIENT, SSH_CONNECTION and the known PAM lines ($n changed lines)" 0
    else
        _c12_check "5 env/ulimit A vs B: no difference other than SSH_CLIENT, SSH_CONNECTION and the known PAM lines" 1 "$unexpected other lines"
    fi
}

# _cross_text KEY LABEL: a text value per config (no assertion)
_cross_text() {
    local a=${REC[A.$1]:-not run} b=${REC[B.$1]:-not run}
    echo "info $2: A $a, B $b"
}

# cross_lines: the computed known-difference lines (A and B values as observed in this run)
cross_lines() {
    C12_CFG=""
    _cross lock_root_mu "locked account key login (root, usermod -L)"
    _cross lock_root_bang "locked account key login (root, field !)"
    _cross lock_admin "locked account key login (admin, usermod -L)"
    _cross exp_key "expired password key login (admin, chage -d 0)"
    _cross exp_pw "expired password password login (admin, chage -d 0)"
    _cross acct_pw "account expired password login (admin, usermod -e 1)"
    _cross acct_key "account expired key login (admin, usermod -e 1)"
    _cross_text nologin "/etc/nologin admin login text"

    local sa=${REC[A.sftp]:-} sb=${REC[B.sftp]:-}
    if [ "$sa" = absent ] && [ "$sb" = absent ]; then
        echo "info sftp subsystem absent on A and B"
    elif [ -n "$sa" ] && [ -n "$sb" ]; then
        echo "info sftp subsystem: A $sa, B $sb"
    elif [ -n "$sb" ]; then
        echo "info sftp subsystem: B $sb"
    fi
}

# ---- main ---------------------------------------------------------------------------------------------------

mkdir -p "$SEC" "$W" "$CTX/files" "$CTX/manager/utils" "$CTX/motd-root/usr/share/unitotem" || finish
chmod 700 "$T" "$SEC" "$W"

for tool in docker ssh ssh-keygen ssh-keyscan scp sftp rsync sshpass openssl git setsid timeout awk sha256sum cmp diff python3; do
    command -v "$tool" >/dev/null 2>&1 || { C12_CFG=""; _c12_check "host tool $tool present" 1 "missing"; finish; }
done
if ! docker info >/dev/null 2>&1; then C12_CFG=""; _c12_check "docker daemon reachable" 1 "docker info failed"; finish; fi
docker rm -f "$SP_CT" >/dev/null 2>&1

# throw-away secrets (0600, in SEC only; never on a command line)
(umask 077
 printf 'Sp%s.1\n' "$(openssl rand -hex 8)" > "$PW_ADMIN"
 printf '\n' > "$PW_EMPTY"
 printf 'Wrong-%s\n' "$(openssl rand -hex 6)" > "$PW_WRONG"
 printf '*\n' > "$PW_STAR"
 printf 'upload-test\n' > "$UP_FILE"
) || { C12_CFG=""; _c12_check "make throw-away secrets" 1 "write failed"; finish; }
for k in "$KEY_ROOT" "$KEY_ADMIN" "$KEY_OTHER" "${WKEYS[@]}"; do
    ssh-keygen -q -t ed25519 -N '' -C sshd-pam-test -f "$k" >/dev/null 2>&1 || { C12_CFG=""; _c12_check "make test key $k" 1 "ssh-keygen"; finish; }
done

# build context: copies of the repo files, the pre-6d22c95 sshd_config from git, the Dockerfile as a heredoc
cp -f "$U/files/unitotem-pwquality" "$U/files/unitotem-motd" "$U/files/motd-20-unitotem" "$CTX/files/" || finish
cp -f "$U/files/sshd_config" "$CTX/files/sshd_config.B" || finish
if ! git -C "$HERE" show 6d22c95~1:unitotem/files/sshd_config > "$CTX/files/sshd_config.A"; then
    C12_CFG=""; _c12_check "config A from git (6d22c95~1)" 1 "git show failed"; finish
fi
cp -f "$M/debian/unitotem-first-admin" "$CTX/files/" || finish
(cd "$M/manager/utils" && tar --exclude=__pycache__ -cf - .) | (cd "$CTX/manager/utils" && tar -xf -) || finish
printf '%s\n' 'NAME="UniTotem"' 'PRETTY_NAME="UniTotem (sshd-pam fixture)"' 'VERSION_ID="2026.11.99"' \
    > "$CTX/motd-root/usr/share/unitotem/unitotem-release" || finish
cat > "$T/Dockerfile" <<'DOCKERFILE'
# sshd/PAM fixture: the login configuration of a UniTotem image (stage1/stage2) on debian:trixie.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server openssh-client openssh-sftp-server \
      libpam-pwquality libpam-systemd python3 python3-loguru \
      sudo rsync procps adduser perl \
 && rm -rf /var/lib/apt/lists/*

# PAM profile (stage2): pam-auth-update rebuilds the PAM stacks from the enabled profiles.
COPY --chmod=644 files/unitotem-pwquality /usr/share/pam-configs/unitotem-pwquality
RUN pam-auth-update --package --force

# Root first-access state (stage2): empty password, first-admin shell, marker group.
RUN groupadd --system unitotem-first-admin \
 && passwd -d root \
 && usermod -s /usr/sbin/unitotem-first-admin -aG unitotem-first-admin root

# First-admin script and the manager modules it imports (debian/rules copies manager/utils as a whole).
COPY --chmod=755 files/unitotem-first-admin /usr/sbin/unitotem-first-admin
COPY manager/utils/ /usr/share/unitotem-manager/utils/
RUN python3 -I -c "import sys; sys.path.insert(0,'/usr/share/unitotem-manager'); from utils import first_access, osusers, passwords" \
 && echo "import check: ok"

# Administrator `admin` made by the manager's own first-access path (create_first_admin). The password comes
# from a build secret, never a layer.
RUN --mount=type=secret,id=admin_pw,required=true python3 -I -c "import sys; sys.path.insert(0,'/usr/share/unitotem-manager'); from utils import first_access; first_access.create_first_admin('admin', open('/run/secrets/admin_pw').read().rstrip('\n'))"

# Login summary (MOTD). The script's ROOT is patched to the fixture tree.
COPY --chmod=755 files/unitotem-motd /usr/share/unitotem/unitotem-motd
COPY --chmod=755 files/motd-20-unitotem /etc/update-motd.d/20-unitotem
COPY motd-root/ /opt/sshd-pam/motd-root/
RUN sed -i 's|^ROOT = os.environ.get("UNITOTEM_MOTD_ROOT", "")|ROOT = "/opt/sshd-pam/motd-root"|' /usr/share/unitotem/unitotem-motd \
 && grep -qx 'ROOT = "/opt/sshd-pam/motd-root"' /usr/share/unitotem/unitotem-motd \
 && { [ ! -e /etc/update-motd.d/10-uname ] || chmod 644 /etc/update-motd.d/10-uname; } \
 && : > /etc/motd

# sshd: variant A = the sshd_config before the login-summary commit (no UsePAM yes), B = the committed one.
COPY --chmod=644 files/sshd_config.A /etc/ssh/sshd_config.A
COPY --chmod=644 files/sshd_config.B /etc/ssh/sshd_config.B
RUN for c in A B; do sed -i 's/^SetEnv LANG=.*/SetEnv LANG=en_US.UTF-8/' /etc/ssh/sshd_config.$c; done \
 && ssh-keygen -A \
 && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh \
 && /usr/sbin/sshd -t -f /etc/ssh/sshd_config.A \
 && /usr/sbin/sshd -t -f /etc/ssh/sshd_config.B

CMD ["sleep", "infinity"]
DOCKERFILE

if DOCKER_BUILDKIT=1 docker build --secret "id=admin_pw,src=$PW_ADMIN" -f "$T/Dockerfile" -t "$SP_IMG" "$CTX" \
    >"$T/build.log" 2>&1; then
    _info "build $SP_IMG from debian:trixie: ok"
else
    tail -n 20 "$T/build.log" >&2
    C12_CFG=""; _c12_check "build $SP_IMG" 1 "docker build failed, log tail on stderr"
    finish
fi

case $MODE in
    both) RUNS="A B" ;;
    A) RUNS="A" ;;
    B) RUNS="B" ;;
esac
for c in $RUNS; do
    run_cfg "$c"
done

if [ "$MODE" != A ]; then
    C12_CFG=""
    sp_cell6_diff
    if [ "$MODE" = both ]; then
        cross_env
    else
        _info "5 env A vs B skipped: config A not run in mode B"
    fi
    cross_lines
fi
finish

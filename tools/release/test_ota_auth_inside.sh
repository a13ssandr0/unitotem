#!/bin/bash
# Runs INSIDE the container of test_ota_auth.sh (root, /repo read-only).
set -uo pipefail
ok=0; fail=0
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $name"; else fail=$((fail + 1)); echo "FAIL: $name"; fi; }
export HOME=/root OTA_PORT=2222
mkdir -p /root/.ssh /etc/dropbear; chmod 700 /root/.ssh
dropbearkey -t ed25519 -f /tmp/hostkey >/dev/null 2>&1
echo /bin/sh >> /etc/shells
HASH=$(openssl passwd -6 secret 2>/dev/null || python3 -c 'import crypt;print(crypt.crypt("secret","$6$salt"))' 2>/dev/null || echo)
[ -n "$HASH" ] || HASH=$(mkpasswd -m sha-512 secret 2>/dev/null || true)
if [ -z "$HASH" ]; then apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq --no-install-recommends openssl >/dev/null 2>&1; HASH=$(openssl passwd -6 secret); fi

serve() {   # serve open|closed : the fallback's accounts and its dropbear
    pkill dropbear 2>/dev/null; sleep 0.3
    if [ "$1" = open ]; then printf 'root::19000:0:99999:7:::\n' > /etc/shadow; else printf 'root:*:19000:0:99999:7:::\nadmin:%s:19000:0:99999:7:::\n' "$HASH" > /etc/shadow; fi
    printf 'root:x:0:0:root:/root:/bin/sh\nadmin:x:0:0::/root:/bin/sh\n' > /etc/passwd
    chmod 600 /etc/shadow
    local opts=(-F -E -p 2222 -r /tmp/hostkey -T 3 -j -k); [ "$1" = open ] && opts+=(-B)
    ( dropbear "${opts[@]}" >/tmp/dropbear.log 2>&1 & )
    for _ in $(seq 1 25); do timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2222' 2>/dev/null && break; sleep 0.2; done
}
resolve() {   # resolve [USER] : runs ota_auth_resolve in a fresh shell and prints the result
    bash -c "source /repo/deploy/script/lib.sh; ota_auth_resolve 127.0.0.1 ${1:-}; rc=\$?; echo \"rc=\$rc mode=\$OTA_RESOLVED_MODE user=\$OTA_RESOLVED_USER key=\$OTA_RESOLVED_KEY\"" 2>&1 </dev/null | tail -1
}
resolve_tty() {   # resolve_tty USER INPUT : the same on a pseudo terminal, INPUT typed on it
    printf '%b' "$2" | script -qec "bash -c 'source /repo/deploy/script/lib.sh; ota_auth_resolve 127.0.0.1 $1; rc=\$?; echo RESULT rc=\$rc mode=\$OTA_RESOLVED_MODE user=\$OTA_RESOLVED_USER'" /dev/null 2>&1 | tr -d '\r' | grep RESULT | tail -1
}

# --- the key of the user, from ~/.ssh
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
serve closed; cp /root/.ssh/id_ed25519.pub /root/.ssh/authorized_keys
R=$(resolve); check "your key from ~/.ssh is found and used" bash -c "echo '$R' | grep -q 'rc=0 mode=key user=root key=/root/.ssh/id_ed25519'"
rm -f /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_rsa_other; cp /root/.ssh/id_rsa_other.pub /root/.ssh/authorized_keys
R=$(resolve); check "another key of ~/.ssh is not tried" bash -c "echo '$R' | grep -q 'rc=1'"
# --- OTA_FALLBACK_KEY wins
ssh-keygen -q -t ed25519 -N '' -f /tmp/explicit; cat /tmp/explicit.pub >> /root/.ssh/authorized_keys
R=$(OTA_FALLBACK_KEY=/tmp/explicit resolve); check "OTA_FALLBACK_KEY is tried first" bash -c "echo '$R' | grep -q 'rc=0 mode=key.*key=/tmp/explicit'"
# --- open: no key, empty root password
rm -f /root/.ssh/authorized_keys
serve open
R=$(resolve); check "an open fallback is detected: root with an empty password" bash -c "echo '$R' | grep -q 'rc=0 mode=open user=root'"
# --- a closed fallback with an administrator: password from the terminal
serve closed
R=$(resolve_tty admin 'secret\n'); check "the password of the administrator is asked on the terminal and accepted" bash -c "echo '$R' | grep -q 'rc=0 mode=password user=admin'"
R=$(resolve_tty '' 'admin\nsecret\n'); check "with no user given the administrator is asked first, then the password" bash -c "echo '$R' | grep -q 'rc=0 mode=password user=admin'"
R=$(resolve_tty admin 'bad\nbad\nbad\n'); check "three wrong passwords end in failure" bash -c "echo '$R' | grep -q 'rc=1'"
R=$(resolve admin); check "no terminal and no key: no password is asked, the login fails" bash -c "echo '$R' | grep -q 'rc=1'"
R=$(resolve_tty root 'x\nx\nx\n'); check "root explicitly: a password is asked and refused when wrong" bash -c "echo '$R' | grep -q 'rc=1'"
echo "$ok passed, $fail failed"; [ "$fail" = 0 ]

#!/bin/bash
# Redeploy that keeps DATA keeps the administrator, end to end (QEMU/KVM, UEFI). No hardware.
#   Phase 1: the recovery fallback deploys the image onto an empty disk; the first administrator is created on the setup page;
#            web login and ssh are checked; the VM is powered off through the QEMU monitor.
#   Phase 2: the installed system is redeployed from the running system with DATA kept (remote-deploy.sh arms the fallback itself,
#            the VM reboots into it, the image is written, DATA is preserved); the administrator must still log in on the web and
#            over ssh, with the same uid and groups, and the hostname must be unchanged.
#   tools/release/test_deploy_identity_e2e.sh [IMAGE.img.xz]     (default: deploy/amd64/unitotem-2026-11-17-amd64.img.xz)
# Scratch: work/deploy-identity-e2e/. Needs docker, /dev/kvm, qemu, OVMF, python3, sshpass, curl.
# Test wrappers in work/deploy-identity-e2e/bin (ssh, scp, curl) run inside the deploy container only: the container shares the host
# network, so the forwarded ports of the VM are reached through them (no port 22 or 443 of the host is used).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG=${1:-$DIR/deploy/amd64/unitotem-2026-11-17-amd64.img.xz}
W="$DIR/work/deploy-identity-e2e"; OUT="$W/out"; BIN="$W/bin"; mkdir -p "$OUT" "$BIN" "$W/backups"
[ -f "$IMG" ] || { echo "no image: $IMG"; exit 1; }
[ -e /dev/kvm ] || { echo "no /dev/kvm"; exit 1; }
FB=2382; WEB=8483; SSHF=2379; FW=uefi
DISK="$W/identity-$FW.img"; VARS="$W/ovmf-vars-identity.fd"; MON="$W/monitor.sock"
PWFILE="$W/admin.pw"; SETUPJSON="$W/setup.json"; ADMIN=admin
SSHDIR="$W/ssh"   # the deploy container's /root/.ssh: the known hosts of the VM and the operator key (test scratch)
mkdir -p -m 700 "$SSHDIR"
ok=0; fail=0
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $n"; else fail=$((fail + 1)); echo "FAIL: $n"; fi; }
cleanup() {
    systemctl --user stop qemu-identity-fb qemu-identity-disk 2>/dev/null
    rm -f -- "$MON" "$PWFILE" "$SETUPJSON" "$DISK" "$VARS" "$SSHDIR/known_hosts" "$SSHDIR/id_ed25519" "$SSHDIR/id_ed25519.pub"
    rmdir -- "$SSHDIR" 2>/dev/null
}
trap cleanup EXIT

# Test password: policy-valid, no part of the user name. Written to a file only (never on a command line).
printf '%s' 'IngMed.N2382' > "$PWFILE"; chmod 600 "$PWFILE"
python3 -I -c 'import json,sys; print(json.dumps({"username": sys.argv[1], "password": open(sys.argv[2]).read()}))' "$ADMIN" "$PWFILE" > "$SETUPJSON"
chmod 600 "$SETUPJSON"

cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
# test wrapper: a call that names 127.0.0.1 without -p reaches the installed system's sshd (host port 2379)
case " $* " in *" -p "*|*" -p"[0-9]*) ;; *127.0.0.1*) set -- -p 2379 "$@" ;; esac
exec /usr/bin/ssh "$@"
EOF
cat > "$BIN/scp" <<'EOF'
#!/bin/bash
# test wrapper: as ssh, with scp's -P
case " $* " in *" -P "*|*" -P"[0-9]*) ;; *127.0.0.1*) set -- -P 2379 "$@" ;; esac
exec /usr/bin/scp "$@"
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
# test wrapper: the HTTPS of the installed system is forwarded to host port 8483 (the probe of the deploy asks port 443)
args=(); for a in "$@"; do args+=("${a//https:\/\/127.0.0.1\//https://127.0.0.1:8483/}"); done
exec /usr/bin/curl "${args[@]}"
EOF
chmod 755 "$BIN/ssh" "$BIN/scp" "$BIN/curl"

# the initrd of the fallback with the engine of the repository appended (a second cpio archive: the later entry wins)
cp "$DIR/build/amd64/recovery/recovery-initrd-amd64.img" "$OUT/initrd"
mkdir -p "$OUT/ov/usr/lib/unitotem"; install -m 755 "$DIR/deploy/script/ota-engine.sh" "$OUT/ov/usr/lib/unitotem/ota-engine.sh"
( cd "$OUT/ov" && printf 'usr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet --owner=0:0 ) >> "$OUT/initrd"
docker build -q -f "$DIR/tools/release/Dockerfile.deploy" -t unitotem-deploy-e2e "$DIR/tools/release" >/dev/null || exit 1

# qemu_start UNIT KIND LOG: KIND fb (recovery kernel, reboots end the VM), disk1 (installed system, reboots end the VM),
# disk2 (installed system, reboots kept: the arming reboots into the fallback and back).
qemu_start() {
    local unit=$1 kind=$2 log=$3 fw
    fw=(-drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on -drive if=pflash,format=raw,unit=1,file="$VARS")
    local args=(-enable-kvm -cpu host -smp 4 -m 4096 -machine q35 -display none "${fw[@]}" -drive "file=$DISK,if=virtio,format=raw"
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$FB-:2222,hostfwd=tcp:127.0.0.1:$WEB-:443,hostfwd=tcp:127.0.0.1:$SSHF-:22"
        -device virtio-net-pci,netdev=n0 -monitor "unix:$MON,server,nowait" -serial "file:$log")
    [ "$kind" = disk2 ] || args+=(-no-reboot)
    if [ "$kind" = fb ]; then
        args+=(-kernel "$DIR/build/amd64/recovery/recovery-vmlinuz-amd64" -initrd "$OUT/initrd" -append "unitotem.ota=recover console=ttyS0,115200")
    fi
    systemd-run --user --unit="$unit" --collect timeout 3600 qemu-system-x86_64 "${args[@]}" >/dev/null 2>&1
}
unit_active() { systemctl --user is-active --quiet "$1"; }
# wait_until SECONDS CMD...: bounded wait (at most 600 s); status of the last try
wait_until() {
    local limit=$1; shift; local end
    [ "$limit" -le 600 ] || limit=600
    end=$((SECONDS + limit))
    while [ "$SECONDS" -lt "$end" ]; do "$@" && return 0; sleep 4; done
    return 1
}
ssh_banner() { timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1 && head -c 20 <&3" 2>/dev/null | grep -q 'SSH-2.0'; }
dropbear_up() { timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$FB && head -c 20 <&3" 2>/dev/null | grep -q dropbear; }
web_login_page() { [ "$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$WEB/login")" = 200 ]; }
web_setup_redirect() { curl -sk -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "https://127.0.0.1:$WEB/login" | grep -q '^307 .*/setup'; }
setup_closed() { [ "$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$WEB/setup")" = 404 ]; }
qmp() { python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); s.recv(4096); s.sendall((sys.argv[2]+"\n").encode()); s.recv(4096)' "$MON" "$1" >/dev/null 2>&1; }
web_login_303() {
    [ "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -X POST -d "username=$ADMIN" --data-urlencode "password@$PWFILE" "https://127.0.0.1:$WEB/auth/token")" = 303 ]
}
# ssh as the administrator: sshpass -e, password only, no askpass, no DISPLAY
ssh_admin() {
    SSHPASS=$(< "$PWFILE") SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS sshpass -e ssh -p "$SSHF" \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 "$ADMIN@127.0.0.1" "$@"
}
ssh_admin_ok() { [ "$(ssh_admin 'id -un' 2>/dev/null)" = "$ADMIN" ]; }

# the deploy container: the host network (the forwarded VM ports are on 127.0.0.1), the wrappers first on PATH
deploy_run() {   # ARGS... : remote-deploy.sh arguments; the log is $OUT/deploy-$PHASE.log
    local log="$OUT/deploy-$PHASE.log"
    OTA_PASSWORD=$(< "$PWFILE") timeout 1200 docker run --rm --privileged --network host --shm-size=24g \
        -v "$DIR:/repo" -v "$(dirname "$IMG"):/img:ro" -v /dev:/dev -v "$BIN:/wbin:ro" -v "$SSHDIR:/root/.ssh" \
        -e PATH=/wbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin -e OTA_PASSWORD \
        -e UNITOTEM_BACKUP_DIR=/repo/work/deploy-identity-e2e/backups unitotem-deploy-e2e \
        bash /repo/deploy/script/remote-deploy.sh "$@" --image "/img/$(basename "$IMG")" --yes > "$log" 2>&1
}

# ---------------------------------------------------------------------------
# Phase 1: fresh disk, the fallback deploys the image
PHASE=phase1
rm -f -- "$DISK" "$VARS"; truncate -s 16G "$DISK"; cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
qemu_start qemu-identity-fb fb "$OUT/serial-fb.log"
up=0; wait_until 600 dropbear_up && up=1
check "phase 1: the fallback (dropbear) is up" [ "$up" = 1 ]
[ "$up" = 1 ] || { echo "$ok passed, $fail failed"; exit 1; }

deploy_run deploy 127.0.0.1:$FB --port 9720; rc=$?
check "phase 1: remote-deploy.sh deploy onto the empty disk exits 0" [ "$rc" = 0 ]
check "phase 1: the fallback login is open (no administrator yet)" grep -q 'Logged in to the fallback as root (open)' "$OUT/deploy-phase1.log"
check "phase 1: the log reaches the reboot into the restored system" grep -q 'Recovery sequence sent' "$OUT/deploy-phase1.log"

# the VM reboots after the deploy: -no-reboot ends its QEMU process
wait_until 180 bash -c "! systemctl --user is-active --quiet qemu-identity-fb"; systemctl --user stop qemu-identity-fb 2>/dev/null
qemu_start qemu-identity-disk disk1 "$OUT/serial-disk1.log"
up=0; wait_until 600 web_setup_redirect && up=1
check "phase 1: the installed system boots and the web UI shows the first-access page" [ "$up" = 1 ]
[ "$up" = 1 ] || { echo "$ok passed, $fail failed"; exit 1; }

setup_code=$(curl -sk -m 20 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary "@$SETUPJSON" "https://127.0.0.1:$WEB/setup")
check "phase 1: POST /setup creates the first administrator ($ADMIN)" [ "$setup_code" = 200 ]
check "phase 1: web login as $ADMIN returns 303" web_login_303
wait_until 300 ssh_banner "$SSHF"
check "phase 1: ssh as $ADMIN works (password)" ssh_admin_ok
UID1=$(ssh_admin 'getent passwd '"$ADMIN"' | cut -d: -f3' 2>/dev/null)
GROUPS1=$(ssh_admin 'id -Gn' 2>/dev/null)
HOST1=$(ssh_admin 'hostname' 2>/dev/null)
echo "phase 1 facts: uid=${UID1:-?} groups=${GROUPS1:-?} hostname=${HOST1:-?}"
check "phase 1: $ADMIN has uid 1000" [ "$UID1" = 1000 ]
check "phase 1: $ADMIN is in the sudo group" bash -c "echo '$GROUPS1' | tr ' ' '\n' | grep -qx sudo"

# clean power off through ACPI (the guest shuts down, QEMU exits by itself)
qmp system_powerdown
wait_until 180 bash -c "! systemctl --user is-active --quiet qemu-identity-disk"
check "phase 1: the VM powers off cleanly (ACPI, QEMU exits without a kill)" bash -c "! systemctl --user is-active --quiet qemu-identity-disk"
systemctl --user stop qemu-identity-disk 2>/dev/null

# ---------------------------------------------------------------------------
# Phase 2: the installed system (DATA holds the accounts) is redeployed with DATA kept, from the running system
PHASE=phase2
qemu_start qemu-identity-disk disk2 "$OUT/serial-disk2.log"
up=0; wait_until 600 ssh_banner "$SSHF" && up=1
check "phase 2: the installed system answers on ssh before the redeploy" [ "$up" = 1 ]
[ "$up" = 1 ] || { echo "$ok passed, $fail failed"; exit 1; }
check "phase 2: $ADMIN logs in before the redeploy" ssh_admin_ok
# the deploy checks the host key of the target (no interactive trust): the VM's key is scanned into the container's known hosts
mkdir -p -m 700 "$SSHDIR"; ssh-keyscan -p "$SSHF" 127.0.0.1 > "$SSHDIR/known_hosts" 2>/dev/null
check "phase 2: the host key of the VM is scanned (known hosts for the deploy)" test -s "$SSHDIR/known_hosts"

deploy_run deploy "$ADMIN@127.0.0.1:$FB" --port 9720; rc=$?
check "phase 2: remote-deploy.sh deploy from the running system (DATA kept, no --wipe-data) exits 0" [ "$rc" = 0 ]
check "phase 2: the log shows the accounts carried onto the new system (DATA kept)" grep -q 'Carrying the local accounts' "$OUT/deploy-phase2.log"
check "phase 2: the log reaches the OTA sequence" grep -q 'OTA sequence sent' "$OUT/deploy-phase2.log"

up=0; wait_until 600 web_login_page && up=1
check "phase 2: the new system answers on the web (login page)" [ "$up" = 1 ]
check "phase 2: web login as $ADMIN still returns 303" web_login_303
check "phase 2: the first-access window stays closed (/setup is 404)" setup_closed
wait_until 300 ssh_banner "$SSHF"
check "phase 2: ssh as $ADMIN still works (password)" ssh_admin_ok
UID2=$(ssh_admin 'getent passwd '"$ADMIN"' | cut -d: -f3' 2>/dev/null)
GROUPS2=$(ssh_admin 'id -Gn' 2>/dev/null)
HOST2=$(ssh_admin 'hostname' 2>/dev/null)
echo "phase 2 facts: uid=${UID2:-?} groups=${GROUPS2:-?} hostname=${HOST2:-?}"
check "phase 2: $ADMIN has uid 1000 (getent passwd)" [ "$UID2" = 1000 ]
check "phase 2: id shows the sudo group" bash -c "echo '$GROUPS2' | tr ' ' '\n' | grep -qx sudo"
check "phase 2: the hostname is unchanged ($HOST1)" [ -n "$HOST1" ] && [ "$HOST1" = "$HOST2" ]

echo "$ok passed, $fail failed"; [ "$fail" = 0 ]

#!/bin/bash
# Power-cut tests for the A/B update path (amd64/UEFI, QEMU). Every scenario starts from a qcow2 overlay of a
# prepared base disk, freezes unitotem-update at a named crashpoint (UPDATE_CRASHPOINT, see the tool), kills
# QEMU with SIGKILL at that moment, boots the same disk again, and checks that the system comes up and that the
# update can then be completed. SSH goes through deploy/lib.sh (_sshpass), as everywhere else in this repo.
#
# Model, and what it does NOT cover: kill -9 of QEMU drops everything the guest had not yet submitted to its
# virtual disk (page cache), which is what a power cut does to the OS. It does not model a physical disk's
# volatile write cache or write reordering, and it cannot cut inside a single block write.
#
#   powercut-ab.sh prep  BASE_RAW RELEASES_DIR   # build base0.qcow2 (A confirmed, nothing fetched)
#   powercut-ab.sh fetched                       # base1.qcow2 = base0 + a completed fetch (the snapshot)
#   powercut-ab.sh run NAME [NAME...]            # scenarios (below); `all` runs every one
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$DIR/deploy/lib.sh" 2>/dev/null
# Base disks and releases are shared (read-only backing files); every job gets its own directory, SSH port and
# serial log, so scenarios can run side by side (`par N ...`) - the VMs are what use the CPU.
ROOTW="$DIR/work/powercut"; PC_ID="${PC_ID:-0}"
W="$ROOTW/job-$PC_ID"; mkdir -p "$W"
PORT=$((2230 + PC_ID)); HTTP_PORT=18081
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
RESULTS="$W/results.txt"
pass=0; failn=0
check() { local d="$1"; shift; if "$@" >"$W/check.out" 2>&1; then echo "PASS: $d" | tee -a "$RESULTS"; pass=$((pass+1)); else echo "FAIL: $d -- $(tail -3 "$W/check.out" | tr '\n' '|')" | tee -a "$RESULTS"; failn=$((failn+1)); fi; }
log() { echo ">>> $*"; }

SSH() { _sshpass ssh -n "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$PORT" root@127.0.0.1 "$@"; }
UU() { SSH "unitotem-update --json $*"; }

VM_PID=""
vm_start() {   # vm_start DISK.qcow2   (serial -> $W/serial.log, appended)
    local disk="$1"
    cp "$OVMF_VARS" "$W/vars.fd" 2>/dev/null || true
    [ -f "$ROOTW/vars.keep" ] && cp "$ROOTW/vars.keep" "$W/vars.fd"
    qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 2 -m 2048 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$W/vars.fd" \
        -drive file="$disk",format=qcow2,if=virtio -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device virtio-net-pci,netdev=n0 \
        -device virtio-vga -display none -serial "file:$W/serial.log" -pidfile "$W/qemu.pid" >"$W/qemu.out" 2>&1 &
    sleep 1; VM_PID=$(cat "$W/qemu.pid" 2>/dev/null || echo "")
}
vm_kill() { [ -n "$VM_PID" ] && kill -9 "$VM_PID" 2>/dev/null; sleep 1; VM_PID=""; }
wait_ssh() { local n=${1:-150} i; for ((i=0;i<n;i+=3)); do SSH true 2>/dev/null && return 0; sleep 3; done; return 1; }
serial_count() { tr -d '\033' < "$W/serial.log" | grep -a -c "$1"; }
wait_serial() {   # wait_serial PATTERN COUNT_AT_LEAST TIMEOUT
    local i; for ((i=0;i<$3*2;i++)); do [ "$(serial_count "$1")" -ge "$2" ] && return 0; sleep 0.5; done; return 1
}
new_run() {   # new_run BASE NAME -> overlay path in $RUN
    RUN="$W/run-$2.qcow2"; rm -f "$RUN"; qemu-img create -q -f qcow2 -b "$1" -F qcow2 "$RUN"; : > "$W/serial.log"
}
clean_shutdown() { SSH 'sync; systemctl poweroff' 2>/dev/null; local i; for ((i=0;i<40;i++)); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 2; done; kill -9 "$VM_PID" 2>/dev/null; VM_PID=""; }

start_fake_server() {
    pgrep -f "fake-github.py --root $REL" >/dev/null && return
    python3 "$DIR/tools/release/fake-github.py" --root "$REL" --bind 127.0.0.1 --port $HTTP_PORT >"$W/fake.log" 2>&1 &
    sleep 1
}
REL="$ROOTW/releases"

set_crashpoint() {   # set_crashpoint NAME   (persisted in the guest's update.conf)
    SSH "sed -i '/^UPDATE_CRASHPOINT=/d' /etc/unitotem/update.conf; echo UPDATE_CRASHPOINT=$1 >> /etc/unitotem/update.conf; sync"
}
slot() { SSH "grep -o 'unitotem.slot=.' /proc/cmdline | cut -d= -f2" 2>/dev/null; }
jfield() { python3 -c "import json,sys; d=json.load(sys.stdin); v=d; 
for k in sys.argv[1].split('.'): v=v.get(k) if isinstance(v,dict) else None
print('' if v is None else v)" "$1"; }

# ---------------------------------------------------------------------------
prep() {
    local raw="$1"; REL="$2"
    log "prep: base0 da $raw"
    qemu-img convert -f raw -O qcow2 "$raw" "$ROOTW/base0.qcow2"
    cp "$OVMF_VARS" "$ROOTW/vars.keep"
    : > "$W/serial.log"; vm_start "$ROOTW/base0.qcow2"; wait_ssh 200 || { echo "VM non raggiungibile"; return 1; }
    # Install the current update tool into slot A (it postdates the image), configure the fake release server.
    SSH 'mount -o remount,rw / ; true'
    _sshpass ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $PORT root@127.0.0.1 'cat > /usr/sbin/unitotem-update.new && chmod 755 /usr/sbin/unitotem-update.new && mv /usr/sbin/unitotem-update.new /usr/sbin/unitotem-update' < "$DIR/kiosk/files/unitotem-update"
    SSH 'mount -o remount,ro / ; mkdir -p /etc/unitotem; printf "UPDATE_BASE_URL=http://10.0.2.2:'$HTTP_PORT'/a13ssandr0/unitotem\nUPDATE_HEALTH_URL=\n" > /etc/unitotem/update.conf; sync'
    UU boot-ok >/dev/null    # confirm the initial trial boot (no health gate here)
    log "stato iniziale: $(UU status | jfield slot) / default $(UU status | jfield default_slot)"
    clean_shutdown; echo "OK base0"
}

fetched() {
    REL="$ROOTW/releases"; start_fake_server
    new_run "$ROOTW/base0.qcow2" fetched
    vm_start "$RUN"; wait_ssh 200 || return 1
    log "fetch completo (snapshot dopo il download)..."
    UU fetch --foreground | tee "$W/fetch.out"
    grep -q '"fetched": true' "$W/fetch.out" || { echo "FETCH FALLITO: base1 non creata"; vm_kill; return 1; }
    clean_shutdown
    cp "$RUN" "$W/base1-overlay.qcow2"
    # flatten: base1 = base0 + fetch
    qemu-img convert -O qcow2 "$RUN" "$ROOTW/base1.qcow2"; rm -f "$RUN" "$W/base1-overlay.qcow2"
    echo "OK base1"
}

# --- scenarios -------------------------------------------------------------
# crash_at BASE NAME POINT COMMAND : boot BASE, set the crashpoint, run COMMAND, kill on the marker, reboot.
crash_at() {
    local base="$1" name="$2" point="$3"; shift 3
    new_run "$base" "$name"; vm_start "$RUN"; wait_ssh 200 || { check "$name: la VM parte" false; return 1; }
    set_crashpoint "$point"
    SSH "nohup sh -c '$*' >/tmp/cmd.out 2>&1 &" 
    if wait_serial "CRASHPOINT $point" 1 150; then
        vm_kill; log "$name: spenta al punto $point"
    else
        check "$name: il punto $point e' stato raggiunto" false; vm_kill; return 1
    fi
    : > "$W/serial.log"; vm_start "$RUN"
    wait_ssh 240 || { check "$name: la VM riparte dopo il taglio" false; return 1; }
    check "$name: la VM riparte dopo il taglio" true
}
final_complete() {   # final_complete NAME : bring the update to a confirmed slot B and roll back once
    local name="$1"
    UU status >"$W/st.json"
    local cur; cur=$(jfield slot < "$W/st.json")
    SSH "sed -i '/^UPDATE_CRASHPOINT=/d' /etc/unitotem/update.conf"
    if [ "$cur" = a ]; then
        UU fetch --foreground >/dev/null 2>&1; local rc=$?
        check "$name: dopo il taglio un nuovo fetch riesce (rc=$rc)" test $rc -eq 0
        UU apply --reboot >/dev/null 2>&1
        # poll for the outcome instead of sleeping: a loaded host makes the boot time vary a lot
        local t
        for ((t=0;t<80;t++)); do
            sleep 3
            UU status >"$W/st.json" 2>/dev/null || continue
            [ "$(jfield slot < "$W/st.json" 2>/dev/null)" = b ] && [ "$(jfield pending_confirm < "$W/st.json" 2>/dev/null)" = False ] && break
        done
    fi
    UU status >"$W/st.json"
    check "$name: a fine prova si e' su B confermato" bash -c "[ \"\$(python3 -c \"import json;d=json.load(open('$W/st.json'));print(d['slot'],d['pending_confirm'])\")\" = 'b False' ]"
    check "$name: il rollback e' disponibile" bash -c "[ \"\$(python3 -c \"import json;print(json.load(open('$W/st.json'))['rollback_available'])\")\" = True ]"
    vm_kill
}

scn_fetch() {   # scn_fetch POINT
    local pt="$1" n="fetch_${1#fetch_}"
    crash_at "$ROOTW/base0.qcow2" "$n" "$pt" "unitotem-update --json fetch --foreground" || return
    UU status >"$W/st.json"
    check "$n: dopo il taglio si e' sullo slot A" bash -c "[ \"\$(python3 -c \"import json;print(json.load(open('$W/st.json'))['slot'])\")\" = a ]"
    check "$n: il default resta A" bash -c "[ \"\$(python3 -c \"import json;print(json.load(open('$W/st.json'))['default_slot'])\")\" = a ]"
    if [ "$pt" = fetch_after_valid ]; then
        check "$n: lo slot B risulta valido (fetch completo)" bash -c "[ \"\$(python3 -c \"import json;print(json.load(open('$W/st.json'))['other_version'])\")\" != '' ]"
    else
        UU apply >"$W/apply.out" 2>&1; local rc=$?
        check "$n: apply rifiuta (slot B non contiene una release verificata), rc=$rc" test $rc -eq 2
    fi
    final_complete "$n"
}
scn_apply() {
    local pt="$1" n="apply_${1#apply_}"
    crash_at "$ROOTW/base1.qcow2" "$n" "$pt" "unitotem-update --json apply --reboot" || return
    UU status >"$W/st.json"
    local cur; cur=$(jfield slot < "$W/st.json")
    if [ "$pt" = apply_after_arm ]; then
        check "$n: il trial era armato -> riparte su B (one-shot)" test "$cur" = b
    else
        check "$n: non armato -> riparte su A" test "$cur" = a
    fi
    final_complete "$n"
}
scn_trial_boot_cut() {   # kill at DELAY seconds after the reboot into the trial slot begins
    local d="$1" n="boot_cut_${1}s"
    new_run "$ROOTW/base1.qcow2" "$n"; vm_start "$RUN"; wait_ssh 200 || return
    local before; before=$(serial_count 'BdsDxe: starting')
    UU apply --reboot >/dev/null
    wait_serial 'BdsDxe: starting' $((before+1)) 120 || { check "$n: nuovo avvio osservato" false; vm_kill; return; }
    sleep "$d"; vm_kill; log "$n: spenta ${d}s dopo l'avvio del firmware verso B"
    : > "$W/serial.log"; vm_start "$RUN"; wait_ssh 240 || { check "$n: la VM riparte" false; return; }
    check "$n: la VM riparte dopo il taglio" true
    # state right after the restart, before boot-ok has had time to touch anything (kept for diagnosis)
    SSH 'cd /mnt/data/unitotem/update 2>/dev/null && for f in slots.json pending.json last-result.json; do echo "== $f"; cat $f 2>&1; echo; done; grub-editenv /boot/efi/unitotem-grub/grub/grubenv list; uptime -s' >"$W/state-after-restart-$d.txt" 2>&1
    UU status >"$W/st.json"; sleep 20; UU status >"$W/st.json"
    local cur; cur=$(jfield slot < "$W/st.json")
    # one-shot already consumed: GRUB goes to the saved default (A) unless B got far enough to confirm
    check "$n: riparte su uno slot funzionante ($cur)" bash -c "[ '$cur' = a ] || [ '$cur' = b ]"
    final_complete "$n"
}
scn_bootside() {   # scn_bootside POINT : crash inside boot-ok / confirm on the trial slot
    local pt="$1" n="b_${1}"
    new_run "$ROOTW/base1.qcow2" "$n"; vm_start "$RUN"; wait_ssh 200 || return
    set_crashpoint "$pt"
    UU apply --reboot >/dev/null
    if wait_serial "CRASHPOINT $pt" 1 240; then vm_kill; else check "$n: raggiunto $pt" false; vm_kill; return; fi
    : > "$W/serial.log"; vm_start "$RUN"; wait_ssh 240 || { check "$n: la VM riparte" false; return; }
    check "$n: la VM riparte dopo il taglio" true
    sleep 30; UU status >"$W/st.json"
    local cur def; cur=$(jfield slot < "$W/st.json"); def=$(jfield default_slot < "$W/st.json")
    if [ "$pt" = confirm_after_default ]; then
        check "$n: il default e' gia' B -> riparte su B" test "$cur" = b
    else
        check "$n: default ancora A -> riparte su A" test "$cur" = a
    fi
    # coherence: the slot we are on must be the default, or a pending trial
    final_complete "$n"
}
scn_rollback() {
    local pt="$1" n="rb_$1"
    # start from "B confirmed": need base2 (flatten of a completed update)
    [ -f "$ROOTW/base2.qcow2" ] || make_base2 || return
    crash_at "$ROOTW/base2.qcow2" "$n" "$pt" "unitotem-update --json rollback --reboot" || return
    UU status >"$W/st.json"; local cur; cur=$(jfield slot < "$W/st.json")
    if [ "$pt" = rollback_after_default ]; then check "$n: default gia' A -> riparte su A" test "$cur" = a
    else check "$n: default ancora B -> riparte su B" test "$cur" = b; fi
    vm_kill
}
make_base2() {
    new_run "$ROOTW/base1.qcow2" base2; vm_start "$RUN"; wait_ssh 200 || return 1
    UU apply --reboot >/dev/null; sleep 20; wait_ssh 240; sleep 30
    [ "$(slot)" = b ] || return 1
    clean_shutdown; qemu-img convert -O qcow2 "$RUN" "$ROOTW/base2.qcow2"
}
scn_torn_grubenv() {
    local n="torn_grubenv"
    new_run "$ROOTW/base1.qcow2" "$n"; vm_start "$RUN"; wait_ssh 200 || return
    # simulate a half-written environment block, then cut the power
    SSH 'dd if=/dev/zero of=/boot/efi/unitotem-grub/grub/grubenv bs=512 count=1 conv=notrunc 2>/dev/null; sync'
    vm_kill; : > "$W/serial.log"; vm_start "$RUN"; wait_ssh 240 || { check "$n: con grubenv illeggibile la VM riparte" false; return; }
    check "$n: con grubenv illeggibile la VM riparte (su uno slot, non nel fallback)" bash -c "[ '$(slot)' = a ] || [ '$(slot)' = b ]"
    vm_kill
}

ALL="fetch_after_invalidate fetch_mid_write fetch_after_write fetch_after_relabel fetch_before_valid fetch_after_valid apply_start apply_after_pending apply_after_arm boot_1 boot_3 boot_6 boot_10 boot_20 boot_40 bootok_health_wait confirm_start confirm_after_default rollback_start rollback_after_default torn_grubenv"
run_one() {
    case "$1" in
        fetch_*) scn_fetch "$1" ;;
        apply_*) scn_apply "$1" ;;
        boot_*) scn_trial_boot_cut "${1#boot_}" ;;
        bootok_health_wait|confirm_start|confirm_after_default) scn_bootside "$1" ;;
        rollback_*) scn_rollback "$1" ;;
        torn_grubenv) scn_torn_grubenv ;;
        *) echo "scenario sconosciuto: $1"; return 1 ;;
    esac
}
cmd="${1:-}"; shift || true
case "$cmd" in
    prep) prep "$@" ;;
    fetched) fetched ;;
    base2) make_base2 && echo "OK base2" ;;
    par)   N="$1"; shift; names="$*"; [ "$names" = all ] && names="$ALL"
           [ -f "$ROOTW/base2.qcow2" ] || { PC_ID=0 "$0" base2 || exit 1; }
           REL="$ROOTW/releases"; start_fake_server
           i=0; for s_ in $names; do i=$((i+1)); echo "$i $s_"; done \
             | xargs -P "$N" -L1 bash -c 'PC_ID=$0 "'"$0"'" run "$1"' 
           cat "$ROOTW"/job-*/results.txt | grep -E '^(PASS|FAIL)' | sort | uniq > "$ROOTW/all-results.txt"
           echo; echo "totale: $(grep -c '^PASS' "$ROOTW/all-results.txt") passati, $(grep -c '^FAIL' "$ROOTW/all-results.txt") falliti"; grep '^FAIL' "$ROOTW/all-results.txt" ;;
    run) : > "$RESULTS"; REL="$ROOTW/releases"; start_fake_server
         names="$*"; [ "$names" = all ] && names="$ALL"
         for s in $names; do log "=== $s ==="; run_one "$s"; vm_kill; done
         echo; echo "$pass passati, $failn falliti" | tee -a "$RESULTS"; [ "$failn" = 0 ] ;;
    *) sed -n 2,16p "$0"; exit 2 ;;
esac

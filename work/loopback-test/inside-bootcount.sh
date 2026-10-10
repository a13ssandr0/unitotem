#!/bin/bash
# Fault injection, PLAN.md §11.5 level 4: the boot counter that decides when a
# system that boots but never confirms itself gets handed back to the fallback.
#
# This is the layer nothing else covers. §11.1's loopback rounds drive the OTA
# from the outside (restore, trial, promote) and never reach cmd_init_premount
# at all, and on real hardware the level-4 path only shows up as an absence -
# a machine that quietly fails to fall back looks exactly like a machine that
# had no reason to. So it gets its own harness rather than another round in
# inside-arm64.sh.
#
# The specific regression risk being pinned down: cmd_init_premount grew a
# trial_reset branch (a trial boot must ignore whatever count already sat on
# disk from an unrelated earlier failure streak, which was a real bug - it
# permanently defeated every future trial). That fix touches the exact
# condition guarding the NON-trial path too, and it is the non-trial path that
# a silent regression would take out first: three unconfirmed boots in a row
# must still hand control back to the fallback. Both directions are asserted
# here, because only asserting the fixed one would pass on code that never
# falls back at all.
#
# Arch-independent on purpose: cmd_init_premount is blkid/mount/e2fsck logic
# with no arm64-specific branch, so this runs in a plain amd64 container
# instead of paying qemu for nothing.
set -Eeuo pipefail

log() { echo ">>> $*"; }

export DEBIAN_FRONTEND=noninteractive
log "Installo i pacchetti necessari nel container..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    util-linux fdisk e2fsprogs dosfstools coreutils gdisk parted procps >/dev/null

REPO=/repo
ENGINE=(bash "$REPO/deploy/ota-engine.sh")
IMG=/work/bootcount.img
RESULTS=/work/results-bootcount.txt
: > "$RESULTS"

record() { echo "$1" | tee -a "$RESULTS"; }
check() {
    local desc="$1"; shift
    if "$@" >/tmp/check.out 2>&1; then
        record "PASS: $desc"
    else
        record "FAIL: $desc -- $(tail -5 /tmp/check.out | tr '\n' '|')"
    fi
}

# --- disco minimo: FIRMWARE (vfat) + ROOT (ext4), gli unici due che
# cmd_init_premount guarda davvero.
log "Preparo un disco con FIRMWARE(vfat) + ROOT(ext4)..."
rm -f "$IMG"
truncate -s 2G "$IMG"
sfdisk "$IMG" >/dev/null << 'EOF'
label: gpt
start=2048, size=524288, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="FIRMWARE"
start=526336, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="ROOT"
EOF

LOOP=$(losetup --find --show --partscan "$IMG")
log "Loop device: $LOOP"

cleanup() {
    set +e
    umount -lf /boot-ota /mnt/fw 2>/dev/null
    umount -lf /proc/cmdline 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# Il kernel legge la tabella e crea le partizioni (compaiono sotto
# /sys/block/<loop>/), ma in questo container non gira udev, quindi nessuno
# materializza i nodi in /dev e ogni mkfs fallirebbe con "No such file or
# directory" su un device che di fatto esiste. Si creano a mano leggendo
# major:minor da sysfs - deterministico e senza dipendere da un udev che qui
# non c'e' (partx -a non aiuta: le partizioni ESISTONO gia' per il kernel,
# infatti risponde "error adding partitions").
lb=$(basename "$LOOP")
for pdir in /sys/block/"$lb"/"$lb"p*; do
    [ -d "$pdir" ] || continue
    pn=$(basename "$pdir")
    IFS=: read -r maj min < "$pdir/dev"
    [ -b "/dev/$pn" ] || mknod "/dev/$pn" b "$maj" "$min"
done
[ -b "${LOOP}p1" ] || { echo "!!! ${LOOP}p1 non e' comparso" >&2; exit 1; }

mkfs.vfat -n FIRMWARE "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L ROOT -F "${LOOP}p2" >/dev/null
udevadm settle --timeout=10 2>/dev/null || true

mkdir -p /mnt/fw

# Il contatore vive sulla partizione FIRMWARE, che cmd_init_premount monta da
# solo su /boot-ota: qui lo si scrive/rilegge montandola separatamente, per
# non dipendere da come la funzione sotto test gestisce i propri mount.
# Ogni caso di fallback lascia /boot-ota montato read-only (cmd_serve_fallback
# non ritorna e non smonta), e il kernel riconsegnerebbe QUELLO stesso
# superblocco a un mount successivo dello stesso device - il mount seguente
# risulterebbe read-only anche chiedendolo in scrittura. E' la stessa trappola
# gia' documentata dentro cmd_init_premount per il contatore di boot; qui va
# neutralizzata tra un caso e l'altro, altrimenti il primo fallback rende
# insensati tutti i controlli che lo seguono.
drop_bootota() {
    umount /boot-ota 2>/dev/null || umount -lf /boot-ota 2>/dev/null || true
}

set_count() {
    drop_bootota
    mount "${LOOP}p1" /mnt/fw
    if [ "$1" = "none" ]; then rm -f /mnt/fw/unitotem-ota.bootcount
    else echo "$1" > /mnt/fw/unitotem-ota.bootcount; fi
    sync; umount /mnt/fw
}
get_count() {
    drop_bootota
    mount -o ro "${LOOP}p1" /mnt/fw
    cat /mnt/fw/unitotem-ota.bootcount 2>/dev/null || echo "ASSENTE"
    umount /mnt/fw
}

# cmdline_get legge /proc/cmdline direttamente. Il bind-mount di un file
# sopra /proc/cmdline e' l'unico modo di esercitare il vero codice invece di
# una copia modificata per il test - possibile solo perche' il container e'
# privilegiato.
set_cmdline() {
    echo "$1" > /tmp/fake-cmdline
    umount /proc/cmdline 2>/dev/null || true
    mount --bind /tmp/fake-cmdline /proc/cmdline
}

# cmd_serve_fallback non ritorna (resta in ascolto con dropbear): si osserva
# la riga di log che stampa PRIMA di bloccarsi, con un timeout. E' la stessa
# riga che comparirebbe su seriale in produzione.
#
# Il timeout che scatta e' l'esito ATTESO nei casi di fallback, quindi va
# raccolto invece di propagato: senza `|| rc=$?` il set -e abortiva l'harness
# proprio sul primo caso che doveva passare.
run_init_premount() {
    drop_bootota
    local rc=0
    timeout 45 "${ENGINE[@]}" init-premount > /tmp/premount.out 2>&1 || rc=$?
    echo "exit=$rc" >> /tmp/premount.out
}

# ---------------------------------------------------------------------------
log "=== 4a: boot NON di trial, contatore gia' a 3 -> deve cadere nel fallback ==="
# Il caso che una regressione silenziosa colpirebbe per primo.
set_count 3
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
run_init_premount
cat /tmp/premount.out
check "4a: fallback innescato dai tre avvii non confermati" \
    grep -q 'tre avvii consecutivi senza conferma' /tmp/premount.out

# ---------------------------------------------------------------------------
log "=== 4b: boot di trial con contatore gia' alto -> deve avviarsi lo stesso ==="
# La direzione corretta dal fix: un trial non deve essere giudicato in base a
# una serie di fallimenti precedenti e scollegata.
set_count 7
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet unitotem.ota.bootcount=1"
run_init_premount
cat /tmp/premount.out
check "4b: nessun fallback su boot di trial" \
    bash -c "! grep -q 'tre avvii consecutivi' /tmp/premount.out"
check "4b: init-premount ritorna 0 (mountroot prosegue)" \
    grep -q 'exit=0' /tmp/premount.out
c=$(get_count); record "4b: contatore dopo il trial = $c (atteso 1, non 8)"
check "4b: il trial azzera il contatore invece di ereditarlo" test "$c" = "1"

# ---------------------------------------------------------------------------
log "=== 4c: boot NON di trial sotto soglia -> prosegue e incrementa ==="
set_count 2
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
run_init_premount
check "4c: nessun fallback a quota 2" \
    bash -c "! grep -q 'tre avvii consecutivi' /tmp/premount.out"
check "4c: init-premount ritorna 0" grep -q 'exit=0' /tmp/premount.out
c=$(get_count); record "4c: contatore dopo l'avvio = $c (atteso 3)"
check "4c: contatore incrementato, non azzerato" test "$c" = "3"

# ---------------------------------------------------------------------------
log "=== 4d: primo avvio in assoluto, nessun contatore -> prosegue e lo crea ==="
set_count none
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
run_init_premount
check "4d: init-premount ritorna 0 senza contatore preesistente" \
    grep -q 'exit=0' /tmp/premount.out

# 4e qui e non piu' in fondo: get_count chiama drop_bootota, che smonterebbe
# /boot-ota e renderebbe questo controllo vacuo (passerebbe su qualsiasi cosa).
# Regressione gia' costata cara su hardware: lasciato montato, il
# boot-firmware.mount del sistema reale fallisce con EBUSY a OGNI avvio e la
# macchina finisce in emergency mode in modo permanente.
log "=== 4e: /boot-ota non deve restare montato dopo un avvio normale ==="
check "4e: /boot-ota smontato al ritorno di init-premount" \
    bash -c '! mountpoint -q /boot-ota'

c=$(get_count); record "4d: contatore creato = $c (atteso 1)"
check "4d: contatore creato a 1" test "$c" = "1"

# ---------------------------------------------------------------------------
log "=== 4f: ROOT assente -> fallback ==="
# L'altro innesco indipendente dal contatore.
set_cmdline "console=tty1 root=LABEL=ROOT ro quiet"
e2label "${LOOP}p2" NOTROOT
udevadm settle --timeout=10 2>/dev/null || true
run_init_premount
check "4f: fallback quando la partizione ROOT non esiste" \
    grep -q 'partizione ROOT non trovata' /tmp/premount.out
e2label "${LOOP}p2" ROOT

# A/B: the slot to validate is the one named in root=, not a fixed "ROOT".
log "=== 4g: layout A/B, root=LABEL=ROOT_B ==="
e2label "${LOOP}p2" ROOT_B
udevadm settle --timeout=10 2>/dev/null || true
rm -f /boot-ota/unitotem-ota.bootcount 2>/dev/null || true
set_cmdline "console=tty1 root=LABEL=ROOT_B ro quiet unitotem.slot=b"
run_init_premount
check "4g: nessun fallback se lo slot B nominato in root= esiste" \
    bash -c '! grep -q "non trovata\|e2fsck" /tmp/premount.out'
set_cmdline "console=tty1 root=LABEL=ROOT_A ro quiet unitotem.slot=a"
run_init_premount
check "4g: fallback se lo slot A nominato in root= non esiste (anche se ROOT_B c'e')" \
    grep -q 'partizione ROOT_A non trovata' /tmp/premount.out
e2label "${LOOP}p2" ROOT

echo
log "=== RISULTATI ==="
cat "$RESULTS"
if grep -q '^FAIL:' "$RESULTS"; then
    echo "!!! Ci sono controlli falliti" >&2
    exit 1
fi
log "Tutti i controlli di livello 4 sono passati."

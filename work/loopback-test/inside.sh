#!/bin/bash
# Runs INSIDE a privileged throwaway container as root. Exercises the real
# deploy/ota-engine.sh subcommand sequence exactly as deploy/remote-deploy.sh's
# run_ota_sequence drives it over SSH in production, but locally against a
# loop device standing in for the target disk - see the OTA redesign plan's
# §11.1 (loopback verification). Mirrors run_ota_sequence's exact ordering
# and flags (deploy/remote-deploy.sh:358-478), simulating a *fresh* (non-
# UniTotem) target so the full table-recreate + DATA-mkfs path gets
# exercised, not just a same-layout restore.
set -Eeuo pipefail

log() { echo ">>> $*"; }
fail() { echo "!!! FALLITO: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Installo i pacchetti necessari nel container..."
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    partclone xz-utils util-linux fdisk e2fsprogs dosfstools coreutils gdisk parted \
    socat procps dctrl-tools file grub-common >/dev/null

REPO=/repo
PARTS=/work/parts
TARGET_IMG=/work/target.img
ENGINE=(bash "$REPO/deploy/ota-engine.sh")
RESULTS=/work/results.txt
: > "$RESULTS"

record() { echo "$1" | tee -a "$RESULTS"; }
check() {
    # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/tmp/check.out 2>&1; then
        record "PASS: $desc"
    else
        record "FAIL: $desc -- $(tail -5 /tmp/check.out | tr '\n' '|')"
    fi
}

SIZE_GIB="${TARGET_SIZE_GIB:-16}"
log "Creo disco target da ${SIZE_GIB}GiB (sparse, piu' grande della sorgente da 11GiB apposta - esercita il ricalcolo size= di DATA, plan §7.4)..."
rm -f "$TARGET_IMG"
truncate -s "${SIZE_GIB}G" "$TARGET_IMG"

LOOP=$(losetup --find --show --partscan "$TARGET_IMG")
log "Loop device: $LOOP"

cleanup() {
    set +e
    umount -lf /mnt/newroot/mnt/data /mnt/newroot/boot/efi /mnt/newroot/boot /mnt/newroot 2>/dev/null
    umount -lf /mnt/ota-bootfs 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# --- parse manifest header -------------------------------------------------
declare -A M
{
    while IFS= read -r line; do
        [ -z "$line" ] && break
        M["${line%%=*}"]="${line#*=}"
    done
} < "$PARTS/parts.manifest"

DATA_PART="${M[UNITOTEM_DATA_PART]}"
BOOTFS_PART="${M[UNITOTEM_BOOTFS_PART]}"
log "manifest: DATA_PART=$DATA_PART BOOTFS_PART=$BOOTFS_PART HAS_ESP=${M[UNITOTEM_HAS_ESP]} RAW_SIZE=${M[UNITOTEM_RAW_SIZE]} TOTAL_USED=${M[UNITOTEM_TOTAL_USED_BYTES]}"

# --- probe (empty disk, must not explode) ----------------------------------
log "=== probe (disco vuoto) ==="
"${ENGINE[@]}" probe --disk "$LOOP" | tee /tmp/probe0.out
check "probe su disco vuoto non segnala HAVE_UNITOTEM" grep -q 'UNITOTEM_HAVE_UNITOTEM=0' /tmp/probe0.out

# --- stage 1: restore-table + bootfs prep + recovery files + default -------
log "=== Stage 1: tabella + fallback ==="
TABLE_B64=$(base64 -w0 < "$PARTS/layout.sfdisk")
BOOTCODE_ARG=()
[ -f "$PARTS/bootcode.bin" ] && BOOTCODE_ARG=(--bootcode-b64 "$(base64 -w0 < "$PARTS/bootcode.bin")")
"${ENGINE[@]}" restore-table --disk "$LOOP" --table-b64 "$TABLE_B64" --tail-part "$DATA_PART" "${BOOTCODE_ARG[@]}"

sfdisk --dump "$LOOP" > /tmp/table-after.sfdisk
record "--- tabella ripristinata (sfdisk --dump) ---"
cat /tmp/table-after.sfdisk | tee -a "$RESULTS"
# Note: sfdisk --dump always reports a last-lba: describing the disk's
# current geometry - that's not a sign of the stripping bug, it's normal
# output. What actually proves last-lba: was stripped from the *input* is
# that DATA grew to fill the bigger target disk below, instead of staying
# capped at its size in the (smaller) source.
# DATA (tail partition) must have grown well past its size in the 11GiB source
data_size_sectors=$(grep -E "${LOOP}p${DATA_PART}[[:space:]]*:" /tmp/table-after.sfdisk | grep -oE 'size=[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
log "DATA size dopo restore-table: ${data_size_sectors} settori (~$((data_size_sectors/2048))MiB)"
check "DATA ricalcolata su disco piu' grande (>4GiB in settori, non la dimensione minuscola originale)" \
    bash -c "[ ${data_size_sectors:-0} -gt 8388608 ]"

# This throwaway container has no running udevd, so the kernel's own
# BLKRRPART re-read (which sfdisk/partx trigger just fine - confirmed via
# sysfs) never gets turned into /dev/loopNpM nodes by anyone. Real targets
# always have udev running, so ota-engine.sh's own partprobe/partx/udevadm
# sequence is correct there; this is purely a test-container gap, worked
# around by mknod'ing straight from sysfs's major:minor.
ensure_partition_nodes() {
    local loop="$1" base p majmin maj min
    base=$(basename "$loop")
    for p in /sys/class/block/${base}p*; do
        [ -e "$p" ] || continue
        local node="/dev/$(basename "$p")"
        [ -b "$node" ] && continue
        majmin=$(cat "$p/dev")
        maj=${majmin%:*}; min=${majmin#*:}
        mknod "$node" b "$maj" "$min"
    done
}
ensure_partition_nodes "$LOOP"

"${ENGINE[@]}" prepare-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --fstype vfat --fresh 1 --label EFI

log "Scrivo kernel/initrd di recovery..."
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-vmlinuz --subdir unitotem \
    < "$REPO/deploy/amd64/recovery-vmlinuz-amd64"
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-initrd.img --subdir unitotem \
    < "$REPO/deploy/amd64/recovery-initrd-amd64.img"

"${ENGINE[@]}" set-default-recovery --disk "$LOOP" --firmware uefi --bootfs-part "$BOOTFS_PART"
log "Stage 1 completato (barriera superata: da qui in poi un fallimento non deve piu' riavviare su un disco a meta')."

# --- stage 2: bootfs file-level content + per-partition restore + DATA -----
log "=== Stage 2: contenuto reale ==="
BOOTFS_STREAM=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "$PARTS/parts.manifest")
if [ -n "$BOOTFS_STREAM" ]; then
    log "Popolo contenuto file-level della boot fs da ${BOOTFS_STREAM}..."
    socat -u "FILE:$PARTS/$BOOTFS_STREAM" "TCP-LISTEN:9700,reuseaddr" &
    NCPID=$!
    sleep 0.5
    "${ENGINE[@]}" populate-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --data-host 127.0.0.1 --data-port 9700
    wait "$NCPID" 2>/dev/null || true
fi

ROOT_PART="" BOOT_PART=""
declare -A BLOCK
process_block() {
    local n="${BLOCK[UNITOTEM_PART]:-}"
    [ -n "$n" ] || return 0
    local label="${BLOCK[UNITOTEM_PART_LABEL]:-}"
    local action="${BLOCK[UNITOTEM_PART_ACTION]:-}"
    case "$label" in
        ROOT) ROOT_PART="$n" ;;
        BOOT) BOOT_PART="$n" ;;
    esac
    case "$action" in
        restore|raw)
            local cloner="${BLOCK[UNITOTEM_PART_CLONER]}"
            local used="${BLOCK[UNITOTEM_PART_USED_BYTES]:-0}"
            local stream="${BLOCK[UNITOTEM_PART_STREAM_FILE]}"
            local comp="${BLOCK[UNITOTEM_PART_COMP]:-xz}"
            log "restore-part $n ($label, cloner=$cloner, used=${used}B)..."
            socat -u "FILE:$PARTS/$stream" "TCP-LISTEN:9701,reuseaddr" &
            local ncpid=$!
            sleep 0.5
            "${ENGINE[@]}" restore-part --disk "$LOOP" --part "$n" --cloner "$cloner" --comp "$comp" \
                --used-bytes "$used" --data-host 127.0.0.1 --data-port 9701 --fstype "${BLOCK[UNITOTEM_PART_FSTYPE]:-}"
            wait "$ncpid" 2>/dev/null || true
            ;;
        data)
            log "data-op mkfs su partizione $n (percorso 'sistema nuovo': tabella ricreata -> DATA formattata)"
            "${ENGINE[@]}" data-op --disk "$LOOP" --part "$n" --op mkfs
            ;;
    esac
}

in_header=1
while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
        if [ "$in_header" = 1 ]; then in_header=0; BLOCK=(); continue; fi
        process_block
        BLOCK=()
        continue
    fi
    [ "$in_header" = 1 ] && continue
    BLOCK["${line%%=*}"]="${line#*=}"
done < "$PARTS/parts.manifest"
process_block

log "ROOT_PART=$ROOT_PART BOOT_PART=$BOOT_PART"
check "ROOT individuata nel manifest" bash -c "[ -n '$ROOT_PART' ]"

# --- mount-target / populate-real-kernel(skip amd64) / migrate-etc-overlay -
log "=== mount-target ==="
MOUNT_ARGS=(--disk "$LOOP" --arch amd64 --root-part "$ROOT_PART" --bootfs-part "$BOOTFS_PART" --data-part "$DATA_PART")
[ -n "$BOOT_PART" ] && MOUNT_ARGS+=(--boot-part "$BOOT_PART")
"${ENGINE[@]}" mount-target "${MOUNT_ARGS[@]}"

check "ROOT montata ha /sbin/init o systemd" bash -c '[ -x /mnt/newroot/sbin/init ] || [ -x /mnt/newroot/usr/lib/systemd/systemd ]'
check "ROOT montata ha /etc/kiosk (marker UniTotem)" test -d /mnt/newroot/etc/kiosk
check "BOOT/ESP montata sotto /boot/efi ha grub" test -d /mnt/newroot/boot/efi/EFI

check "unitotem-ota-changes installato" test -x /mnt/newroot/usr/sbin/unitotem-ota-changes
check "baseline generata da stage3" test -s /mnt/newroot/usr/lib/unitotem/baseline/packages
check "baseline: manifest dei file non posseduti non vuoto" \
    test -s /mnt/newroot/usr/lib/unitotem/baseline/unowned.sha256
# Il numero esatto varia, ma un ordine di grandezza sbagliato tradisce una
# normalizzazione usr-merge rotta: senza, i "non posseduti" raddoppiano.
check "baseline: conteggio dei non posseduti plausibile (<6000)" \
    bash -c '[ "$(wc -l < /mnt/newroot/usr/lib/unitotem/baseline/unowned.sha256)" -lt 6000 ]'
check "baseline: il manifest non contiene se stesso" \
    bash -c "! grep -q '/usr/lib/unitotem/baseline/' /mnt/newroot/usr/lib/unitotem/baseline/unowned.sha256"
check "l'hook overlay ancora /var/lib/dpkg su ROOT" \
    grep -q 'dpkg_pin' /mnt/newroot/etc/initramfs-tools/scripts/init-bottom/setup-overlays
check "timer apt automatici mascherati" \
    bash -c 'ls -l /mnt/newroot/etc/systemd/system/apt-daily.timer 2>/dev/null | grep -q /dev/null'
check "kiosk-update ferma i servizi reali, non sway" \
    bash -c "grep -q 'start-xorg.service' /mnt/newroot/usr/local/bin/kiosk-update && ! grep -q 'pkill -x sway' /mnt/newroot/usr/local/bin/kiosk-update"

# Stessi controlli di confezionamento del lato arm64: fstab-amd64 e' stato
# modificato in parallelo a fstab-arm64, e "e' simmetrico quindi va bene" non
# e' una verifica. L'hook overlay invece e' condiviso fra le due architetture.
check "l'hook overlay copre anche /var" \
    grep -qE 'for d in etc root var' /mnt/newroot/etc/initramfs-tools/scripts/init-bottom/setup-overlays
check "fstab non rimonta piu' tmpfs su /var/lib/* (maschererebbe l'overlay)" \
    bash -c "! grep -qE '^tmpfs[[:space:]]+/var/lib/' /mnt/newroot/etc/fstab"
check "fstab tiene comunque /var/cache e /var/tmp su tmpfs (usura disco)" \
    bash -c "grep -qE '^tmpfs[[:space:]]+/var/cache' /mnt/newroot/etc/fstab && grep -qE '^tmpfs[[:space:]]+/var/tmp' /mnt/newroot/etc/fstab"
check "journald chiede storage persistente" \
    bash -c "grep -rqs '^Storage=persistent' /mnt/newroot/etc/systemd/journald.conf.d/"

DATA_MNT=/mnt/newroot/mnt/data
mkdir -p "$DATA_MNT/upper/etc/cron.d" "$DATA_MNT/upper/var/lib/dpkg"
echo "vecchio-db" > "$DATA_MNT/upper/var/lib/dpkg/status"
echo "sostituiscimi" > "$DATA_MNT/upper/etc/cron.d/estraneo"

"${ENGINE[@]}" migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt /mnt/newroot/mnt/data

check "migrate: upper/var azzerato (niente dpkg della vecchia immagine)" \
    bash -c "! test -e '$DATA_MNT/upper/var/lib/dpkg/status'"
check "migrate: il vecchio /var e' archiviato in history, non perso" \
    bash -c "ls '$DATA_MNT'/history/*/var/lib/dpkg/status >/dev/null 2>&1"
check "migrate: file /etc non in whitelist NON reimportato" \
    bash -c "! test -e '$DATA_MNT/upper/etc/cron.d/estraneo'"

log "=== set-trial-boot (uefi, chroot sul target appena scritto) ==="
"${ENGINE[@]}" set-trial-boot --firmware uefi --target /mnt/newroot
check "voce grub di trial creata" test -f /mnt/newroot/etc/grub.d/99_unitotem_trial
check "grub.cfg rigenerato menziona 'UniTotem (trial)'" grep -q 'UniTotem (trial)' /mnt/newroot/boot/grub/grub.cfg
check "grubenv punta al trial come next entry" bash -c "grub-editenv /mnt/newroot/boot/grub/grubenv list 2>/dev/null | grep -q 'next_entry=.*UniTotem (trial)'"

# --- verify recovery files were NOT clobbered by stage 2's bootfs populate -
# bootfs is already mounted (by mount-target, above) at /mnt/newroot/boot/efi
# - mounting the same partition a second time at /mnt/ota-bootfs would just
# collide with that, so read it straight from where it already is.
log "=== verifica: i file di recovery sopravvivono al populate-bootfs di stage 2 ==="
BOOTFS_MNT=/mnt/newroot/boot/efi
check "recovery-vmlinuz ancora presente" test -f "$BOOTFS_MNT/unitotem/recovery-vmlinuz"
check "recovery-initrd.img ancora presente" test -f "$BOOTFS_MNT/unitotem/recovery-initrd.img"
got_vmlinuz_sha=$(sha256sum "$BOOTFS_MNT/unitotem/recovery-vmlinuz" | cut -d' ' -f1)
got_initrd_sha=$(sha256sum "$BOOTFS_MNT/unitotem/recovery-initrd.img" | cut -d' ' -f1)
exp_vmlinuz_sha=$(awk -F= '/UNITOTEM_RECOVERY_VMLINUZ_SHA256/{print $2}' "$REPO/deploy/amd64/recovery.manifest")
exp_initrd_sha=$(awk -F= '/UNITOTEM_RECOVERY_INITRD_SHA256/{print $2}' "$REPO/deploy/amd64/recovery.manifest")
record "recovery-vmlinuz sha256: got=${got_vmlinuz_sha} expected=${exp_vmlinuz_sha}"
check "recovery-vmlinuz sha256 corretto (riletto dal disco)" bash -c "[ '$got_vmlinuz_sha' = '$exp_vmlinuz_sha' ]"
record "recovery-initrd.img sha256: got=${got_initrd_sha} expected=${exp_initrd_sha}"
check "recovery-initrd.img sha256 corretto (riletto dal disco)" bash -c "[ '$got_initrd_sha' = '$exp_initrd_sha' ]"
check "BOOTX64.EFI presente (popolato da stage 2 file-level, non clobbera unitotem/)" test -f "$BOOTFS_MNT/EFI/BOOT/BOOTX64.EFI"
check "grub.cfg di default-recovery ancora presente e punta al fallback" grep -q "recovery-vmlinuz" "$BOOTFS_MNT/grub/grub.cfg"

log "=== umount-target ==="
"${ENGINE[@]}" umount-target

# --- fsck a freddo su ogni partizione ripristinata --------------------------
log "=== fsck a freddo ==="
check "fsck.ext4 pulito su ROOT" e2fsck -fn "${LOOP}p${ROOT_PART}"
[ -n "$BOOT_PART" ] && check "fsck.ext4 pulito su BOOT" e2fsck -fn "${LOOP}p${BOOT_PART}"
check "fsck.vfat pulito su bootfs (EFI)" fsck.vfat -n "${LOOP}p${BOOTFS_PART}"
check "fsck.ext4 pulito su DATA (appena formattata)" e2fsck -fn "${LOOP}p${DATA_PART}"
check "label DATA corretta" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p${DATA_PART})\" = DATA ]"

# --- promote-default: chroot nel target, esattamente come farebbe -----------
# unitotem-boot-ok.service dopo un avvio confermato del sistema reale.
log "=== promote-default (simulando boot confermato) ==="
"${ENGINE[@]}" mount-target "${MOUNT_ARGS[@]}"
cp "$REPO/deploy/ota-engine.sh" /mnt/newroot/tmp/ota-engine.sh
mount --bind /dev  /mnt/newroot/dev
mount --bind /proc /mnt/newroot/proc
mount --bind /sys  /mnt/newroot/sys
chroot /mnt/newroot bash /tmp/ota-engine.sh promote-default --firmware uefi
umount -lf /mnt/newroot/dev /mnt/newroot/proc /mnt/newroot/sys
check "voce di trial rimossa dopo promote-default" bash -c '[ ! -f /mnt/newroot/etc/grub.d/99_unitotem_trial ]'
check "grub.cfg rigenerato NON menziona piu' il trial dopo promote" bash -c '! grep -q "UniTotem (trial)" /mnt/newroot/boot/grub/grub.cfg'
rm -f /mnt/newroot/tmp/ota-engine.sh
"${ENGINE[@]}" umount-target

log "=== RISULTATI ==="
cat "$RESULTS"
if grep -q '^FAIL' "$RESULTS"; then
    log "ALCUNI CONTROLLI SONO FALLITI"
    exit 1
else
    log "TUTTI I CONTROLLI SONO PASSATI"
fi

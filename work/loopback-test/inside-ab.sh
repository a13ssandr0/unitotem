#!/bin/bash
# A/B first-deploy harness (amd64/UEFI). Runs INSIDE a privileged container, drives deploy/ota-engine.sh
# in exactly the order deploy/remote-deploy.sh's run_ota_sequence uses for a layout-2 parts set, against a
# loop device, and leaves the resulting disk (/work/target.img) for a QEMU boot test on the host.
# Differences from inside.sh: GRUB state is a plain file write (no chroot/grub tools), the boot partition is
# populated BEFORE set-default-recovery, ROOT_B is only formatted, overlay state is per-slot.
set -Eeuo pipefail
log() { echo ">>> $*"; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends partclone xz-utils util-linux fdisk e2fsprogs dosfstools coreutils \
    gdisk parted socat procps dctrl-tools file >/dev/null

REPO=/repo; PARTS=/work/parts; TARGET_IMG=/work/target.img
ENGINE=(bash "$REPO/deploy/ota-engine.sh")
RESULTS=/work/results.txt; : > "$RESULTS"
record() { echo "$1" | tee -a "$RESULTS"; }
check() { local d="$1"; shift; if "$@" >/tmp/check.out 2>&1; then record "PASS: $d"; else record "FAIL: $d -- $(tail -5 /tmp/check.out | tr '\n' '|')"; fi; }

rm -f "$TARGET_IMG"; truncate -s 16G "$TARGET_IMG"
LOOP=$(losetup --find --show --partscan "$TARGET_IMG")
cleanup() { set +e; umount -lf /mnt/newroot/mnt/data /mnt/newroot/boot/efi /mnt/newroot 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }
trap cleanup EXIT

declare -A M
while IFS= read -r line; do [ -z "$line" ] && break; M["${line%%=*}"]="${line#*=}"; done < "$PARTS/parts.manifest"
DATA_PART="${M[UNITOTEM_DATA_PART]}"; BOOTFS_PART="${M[UNITOTEM_BOOTFS_PART]}"
check "il parts set dichiara layout 2" test "${M[UNITOTEM_LAYOUT]:-1}" = 2

ensure_partition_nodes() {
    local base p majmin; base=$(basename "$LOOP")
    for p in /sys/class/block/${base}p*; do
        [ -e "$p" ] || continue
        [ -b "/dev/$(basename "$p")" ] && continue
        majmin=$(cat "$p/dev"); mknod "/dev/$(basename "$p")" b "${majmin%:*}" "${majmin#*:}"
    done
}

log "=== Stage 1 ==="
TABLE_B64=$(base64 -w0 < "$PARTS/layout.sfdisk")
BC=(); [ -f "$PARTS/bootcode.bin" ] && BC=(--bootcode-b64 "$(base64 -w0 < "$PARTS/bootcode.bin")")
"${ENGINE[@]}" restore-table --disk "$LOOP" --table-b64 "$TABLE_B64" --tail-part "$DATA_PART" "${BC[@]}"
ensure_partition_nodes

VOLID=$(awk -F= '/^UNITOTEM_PART_VOLID=/{print $2; exit}' "$PARTS/parts.manifest")
check "il manifest registra il volid della partizione di boot" test -n "$VOLID"
"${ENGINE[@]}" prepare-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --fstype vfat --fresh 1 --label EFI --volid "$VOLID"
check "il volid FAT e' stato preservato (GRUB lo cerca per UUID)" bash -c "[ \"\$(blkid -s UUID -o value ${LOOP}p${BOOTFS_PART})\" = '$VOLID' ]"

"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-vmlinuz --subdir unitotem < "$REPO/deploy/amd64/recovery-vmlinuz-amd64"
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-initrd.img --subdir unitotem < "$REPO/deploy/amd64/recovery-initrd-amd64.img"

STREAM=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "$PARTS/parts.manifest")
socat -u "FILE:$PARTS/$STREAM" "TCP-LISTEN:9700,reuseaddr" & NC=$!; sleep 0.5
"${ENGINE[@]}" populate-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --data-host 127.0.0.1 --data-port 9700
wait "$NC" 2>/dev/null || true

"${ENGINE[@]}" set-default-recovery --disk "$LOOP" --firmware uefi --bootfs-part "$BOOTFS_PART" --layout ab
mkdir -p /mnt/esp; mount "${LOOP}p${BOOTFS_PART}" /mnt/esp
GE=/mnt/esp/unitotem-grub/grub/grubenv
check "grubenv: 1024 byte" bash -c "[ \$(stat -c %s $GE) = 1024 ]"
check "grubenv: saved_entry=ota-recovery dopo lo stage 1" grep -q '^saved_entry=ota-recovery$' "$GE"
check "grub.cfg contiene la voce ota-recovery" grep -q -- '--id ota-recovery' /mnt/esp/unitotem-grub/grub/grub.cfg
check "BOOTX64.EFI presente" test -f /mnt/esp/EFI/BOOT/BOOTX64.EFI
check "i file di recovery sono sopravvissuti al populate" test -f /mnt/esp/unitotem/recovery-initrd.img
umount /mnt/esp

log "=== Stage 2 ==="
declare -A BLOCK
ROOT_PART=""
process_block() {
    local n="${BLOCK[UNITOTEM_PART]:-}"; [ -n "$n" ] || return 0
    local label="${BLOCK[UNITOTEM_PART_LABEL]:-}" action="${BLOCK[UNITOTEM_PART_ACTION]:-}"
    [ "$label" = ROOT_A ] && ROOT_PART="$n"
    case "$action" in
        restore|raw)
            socat -u "FILE:$PARTS/${BLOCK[UNITOTEM_PART_STREAM_FILE]}" "TCP-LISTEN:9701,reuseaddr" & local pid=$!; sleep 0.5
            "${ENGINE[@]}" restore-part --disk "$LOOP" --part "$n" --cloner "${BLOCK[UNITOTEM_PART_CLONER]}" --comp "${BLOCK[UNITOTEM_PART_COMP]:-xz}" \
                --used-bytes "${BLOCK[UNITOTEM_PART_USED_BYTES]:-0}" --data-host 127.0.0.1 --data-port 9701 --fstype "${BLOCK[UNITOTEM_PART_FSTYPE]:-}"
            wait "$pid" 2>/dev/null || true ;;
        format) "${ENGINE[@]}" format-part --disk "$LOOP" --part "$n" --label "$label" ;;
        data)   "${ENGINE[@]}" data-op --disk "$LOOP" --part "$n" --op mkfs ;;
    esac
}
in_header=1
while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then if [ "$in_header" = 1 ]; then in_header=0; BLOCK=(); continue; fi; process_block; BLOCK=(); continue; fi
    [ "$in_header" = 1 ] && continue
    BLOCK["${line%%=*}"]="${line#*=}"
done < "$PARTS/parts.manifest"
process_block
check "ROOT_A individuata" test -n "$ROOT_PART"

"${ENGINE[@]}" mount-target --disk "$LOOP" --arch amd64 --root-part "$ROOT_PART" --bootfs-part "$BOOTFS_PART" --data-part "$DATA_PART"
check "ROOT_A montata ha systemd" test -x /mnt/newroot/usr/lib/systemd/systemd
check "release-version presente nell'immagine" test -s /mnt/newroot/usr/share/unitotem/release-version
check "chiave radice reale installata" test -s /mnt/newroot/usr/share/unitotem/update-keys/root.pub
check "fstab senza riga / e senza BOOT" bash -c "! grep -qE '^LABEL=(ROOT|BOOT)[[:space:]]' /mnt/newroot/etc/fstab"

D=/mnt/newroot/mnt/data
# stale state from a previous install: slot-b overlay and update bookkeeping must be reset, slot-a's old etc archived
mkdir -p "$D/upper/etc.a" "$D/upper/etc.b" "$D/upper/var.a" "$D/unitotem/update"
echo old > "$D/upper/etc.a/hostname"; echo stale > "$D/upper/etc.b/leftover"; echo '{}' > "$D/unitotem/update/pending.json"
"${ENGINE[@]}" migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt "$D" --slot a
check "migrate --slot a: la whitelist porta hostname nel nuovo etc.a" test -f "$D/upper/etc.a/hostname"
check "migrate --slot a: l'overlay dello slot B obsoleto e' stato azzerato" bash -c "! test -e '$D/upper/etc.b'"
check "migrate --slot a: pending.json obsoleto rimosso" bash -c "! test -e '$D/unitotem/update/pending.json'"
check "migrate --slot a: nessun upper/etc senza suffisso creato" bash -c "! test -e '$D/upper/etc'"

"${ENGINE[@]}" set-trial-boot --firmware uefi --target /mnt/newroot --layout ab
GE=/mnt/newroot/boot/efi/unitotem-grub/grub/grubenv
check "trial: saved_entry resta sul fallback" grep -q '^saved_entry=ota-recovery$' "$GE"
check "trial: next_entry=slot-a (one-shot)" grep -q '^next_entry=slot-a$' "$GE"
check "trial: pending.json scritto sullo slot a" grep -q '"slot": "a"' "$D/unitotem/update/pending.json"
check "trial: slots.json scritto" test -s "$D/unitotem/update/slots.json"
"${ENGINE[@]}" umount-target

check "fsck ROOT_A" e2fsck -fn "${LOOP}p${ROOT_PART}"
check "fsck ROOT_B (appena formattata)" e2fsck -fn "${LOOP}p$((ROOT_PART+1))"
check "label ROOT_B" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p$((ROOT_PART+1)))\" = ROOT_B ]"
check "label ROOT_A" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p${ROOT_PART})\" = ROOT_A ]"
check "fsck.vfat bootfs" fsck.vfat -n "${LOOP}p${BOOTFS_PART}"
check "fsck DATA" e2fsck -fn "${LOOP}p${DATA_PART}"

log "=== RISULTATI ==="; cat "$RESULTS"
grep -q '^FAIL' "$RESULTS" && { log "ALCUNI CONTROLLI SONO FALLITI"; exit 1; }
log "TUTTI I CONTROLLI SONO PASSATI"

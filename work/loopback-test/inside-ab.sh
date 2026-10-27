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
ARCH="${ARCH:-amd64}"   # amd64 (UEFI, GRUB) or arm64 (Raspberry, tryboot)
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
check "the parts set declares layout 2" test "${M[UNITOTEM_LAYOUT]:-1}" = 2

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

BOOTFS_LABEL=EFI; [ "$ARCH" = arm64 ] && BOOTFS_LABEL=FIRMWARE

# The property that matters is "the firmware can boot this config": for a Pi config (config.txt or
# tryboot.txt) every file it makes the firmware load - kernel, initramfs, the board's device tree,
# cmdline.txt - must exist under the directory os_prefix selects.
pi_config_bootable() {   # pi_config_bootable MNT CONFIGFILE
    local mnt="$1" cfg="$2" prefix k i
    prefix=$(sed -n 's/^os_prefix=//p' "$mnt/$cfg" | tail -1)
    k=$(sed -n 's/^kernel=//p' "$mnt/$cfg" | tail -1); k=${k:-kernel8.img}
    i=$(sed -n 's/^initramfs \([^ ]*\) followkernel.*/\1/p' "$mnt/$cfg" | tail -1)
    local d="$mnt/$prefix" ok=0 f
    for f in "$k" ${i:+"$i"} bcm2711-rpi-4-b.dtb cmdline.txt; do
        if [ ! -s "$d$f" ]; then echo "MISSING: ${prefix}${f}" >&2; ok=1; fi
    done
    return $ok
}
# Reproduce the flag-file fallback: init-premount leaves the boot partition mounted ro on /boot-ota,
# and prepare-bootfs must release it before mkfs.fat ("contains a mounted filesystem").
mkfs.fat -F32 "${LOOP}p${BOOTFS_PART}" >/dev/null 2>&1
mkdir -p /boot-ota; mount -t vfat -o ro "${LOOP}p${BOOTFS_PART}" /boot-ota
VOLID=$(awk -F= '/^UNITOTEM_PART_VOLID=/{print $2; exit}' "$PARTS/parts.manifest")
check "the manifest records the volid of the boot partition" test -n "$VOLID"
"${ENGINE[@]}" prepare-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --fstype vfat --fresh 1 --label "$BOOTFS_LABEL" --volid "$VOLID"
check "prepare-bootfs released /boot-ota before formatting" bash -c '! mountpoint -q /boot-ota'
check "the FAT volid was preserved (GRUB looks it up by UUID)" bash -c "[ \"\$(blkid -s UUID -o value ${LOOP}p${BOOTFS_PART})\" = '$VOLID' ]"

if [ "$ARCH" = arm64 ]; then RNAME=recovery8.img; RSUB=(); else RNAME=recovery-vmlinuz; RSUB=(--subdir unitotem); fi
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name "$RNAME" "${RSUB[@]}" < "$REPO/deploy/$ARCH/recovery-vmlinuz-$ARCH"
"${ENGINE[@]}" write-bootfile --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --name recovery-initrd.img "${RSUB[@]}" < "$REPO/deploy/$ARCH/recovery-initrd-$ARCH.img"

STREAM=$(awk -F= '/^UNITOTEM_PART_LABEL=(EFI|FIRMWARE)/{f=1} f&&/^UNITOTEM_PART_STREAM_FILE=/{print $2; exit}' "$PARTS/parts.manifest")
socat -u "FILE:$PARTS/$STREAM" "TCP-LISTEN:9700,reuseaddr" & NC=$!; sleep 0.5
"${ENGINE[@]}" populate-bootfs --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --data-host 127.0.0.1 --data-port 9700 --layout ab
wait "$NC" 2>/dev/null || true

"${ENGINE[@]}" set-default-recovery --disk "$LOOP" --firmware "$([ "$ARCH" = arm64 ] && echo rpi || echo uefi)" --bootfs-part "$BOOTFS_PART" --layout ab
mkdir -p /mnt/esp; mount "${LOOP}p${BOOTFS_PART}" /mnt/esp
if [ "$ARCH" = arm64 ]; then
    check "config.txt points to the fallback after stage 1" grep -q '^kernel=recovery8.img$' /mnt/esp/config.txt
    check "slota/kernel8.img present (populate brought the slot directory)" test -s /mnt/esp/slota/kernel8.img
    check "slota/initramfs8 present" test -s /mnt/esp/slota/initramfs8
    check "slota/cmdline.txt survived the tar excludes" test -s /mnt/esp/slota/cmdline.txt
    check "slota/cmdline.txt: root=LABEL=ROOT_A and slot=a" bash -c "grep -q 'root=LABEL=ROOT_A' /mnt/esp/slota/cmdline.txt && grep -q 'unitotem.slot=a' /mnt/esp/slota/cmdline.txt"
    check "top-level cmdline.txt is the fallback's (not the slot's)" grep -q 'unitotem.ota=1' /mnt/esp/cmdline.txt
    check "slota/dtb present" bash -c "ls /mnt/esp/slota/bcm2711-rpi-4-b.dtb"
    check "the shared firmware is at the top level (start4.elf)" test -f /mnt/esp/start4.elf
    check "the recovery files survived populate" test -s /mnt/esp/recovery-initrd.img
    check "BOOT PROPERTY: the fallback (config.txt) has everything the firmware loads (kernel, initramfs, dtb, cmdline)" pi_config_bootable /mnt/esp config.txt
else
    GE=/mnt/esp/unitotem-grub/grub/grubenv
    check "grubenv: 1024 byte" bash -c "[ \$(stat -c %s $GE) = 1024 ]"
    check "grubenv: saved_entry=ota-recovery after stage 1" grep -q '^saved_entry=ota-recovery$' "$GE"
    check "grub.cfg has the ota-recovery entry" grep -q -- '--id ota-recovery' /mnt/esp/unitotem-grub/grub/grub.cfg
    check "BOOTX64.EFI present" test -f /mnt/esp/EFI/BOOT/BOOTX64.EFI
    check "the recovery files survived populate" test -f /mnt/esp/unitotem/recovery-initrd.img
fi
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
check "ROOT_A found" test -n "$ROOT_PART"

"${ENGINE[@]}" mount-target --disk "$LOOP" --arch "$ARCH" --root-part "$ROOT_PART" --bootfs-part "$BOOTFS_PART" --data-part "$DATA_PART"
check "mounted ROOT_A has systemd" test -x /mnt/newroot/usr/lib/systemd/systemd
check "release-version present in the image" test -s /mnt/newroot/usr/share/unitotem/release-version
check "real root key installed" test -s /mnt/newroot/usr/share/unitotem/update-keys/root.pub
check "fstab without a / line and without BOOT" bash -c "! grep -qE '^LABEL=(ROOT|BOOT)[[:space:]]' /mnt/newroot/etc/fstab"

D=/mnt/newroot/mnt/data
# stale state from a previous install: slot-b overlay and update bookkeeping must be reset, slot-a's old etc archived
mkdir -p "$D/upper/etc.a" "$D/upper/etc.b" "$D/upper/var.a" "$D/unitotem/update"
echo old > "$D/upper/etc.a/hostname"; echo stale > "$D/upper/etc.b/leftover"; echo '{}' > "$D/unitotem/update/pending.json"
"${ENGINE[@]}" migrate-etc-overlay --root-mnt /mnt/newroot --data-mnt "$D" --slot a
check "migrate --slot a: the whitelist carries hostname into the new etc.a" test -f "$D/upper/etc.a/hostname"
check "migrate --slot a: the stale slot B overlay was cleared" bash -c "! test -e '$D/upper/etc.b'"
check "migrate --slot a: stale pending.json removed" bash -c "! test -e '$D/unitotem/update/pending.json'"
check "migrate --slot a: no suffix-less upper/etc created" bash -c "! test -e '$D/upper/etc'"

if [ "$ARCH" = arm64 ]; then
    "${ENGINE[@]}" set-trial-boot --firmware rpi-tryboot --disk "$LOOP" --bootfs-part "$BOOTFS_PART" --target /mnt/newroot --layout ab
    TB=/mnt/newroot/boot/firmware/tryboot.txt
    check "trial rpi: tryboot.txt con os_prefix=slota/" grep -q '^os_prefix=slota/$' "$TB"
    check "trial rpi: tryboot.txt is a complete config (kernel + initramfs)" bash -c "grep -q '^kernel=kernel8.img$' $TB && grep -q '^initramfs initramfs8 followkernel$' $TB"
    check "trial rpi: config.txt stays on the fallback" grep -q '^kernel=recovery8.img$' /mnt/newroot/boot/firmware/config.txt
    check "trial rpi: no cmdline=: the cmdline comes from the slot via os_prefix" bash -c "! grep -q '^cmdline=' $TB"
    check "BOOT PROPERTY: the trial (tryboot.txt) has everything the firmware loads" pi_config_bootable /mnt/newroot/boot/firmware tryboot.txt
    check "BOOT PROPERTY: the fallback stays bootable after the trial (config.txt)" pi_config_bootable /mnt/newroot/boot/firmware config.txt
else
    "${ENGINE[@]}" set-trial-boot --firmware uefi --target /mnt/newroot --layout ab
    GE=/mnt/newroot/boot/efi/unitotem-grub/grub/grubenv
    check "trial: saved_entry stays on the fallback" grep -q '^saved_entry=ota-recovery$' "$GE"
    check "trial: next_entry=slot-a (one-shot)" grep -q '^next_entry=slot-a$' "$GE"
fi
check "trial: pending.json written for slot a" grep -q '"slot": "a"' "$D/unitotem/update/pending.json"
check "trial: slots.json written" test -s "$D/unitotem/update/slots.json"
"${ENGINE[@]}" umount-target

check "fsck ROOT_A" e2fsck -fn "${LOOP}p${ROOT_PART}"
check "fsck ROOT_B (just formatted)" e2fsck -fn "${LOOP}p$((ROOT_PART+1))"
check "label ROOT_B" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p$((ROOT_PART+1)))\" = ROOT_B ]"
check "label ROOT_A" bash -c "[ \"\$(blkid -s LABEL -o value ${LOOP}p${ROOT_PART})\" = ROOT_A ]"
check "fsck.vfat bootfs" fsck.vfat -n "${LOOP}p${BOOTFS_PART}"
check "fsck DATA" e2fsck -fn "${LOOP}p${DATA_PART}"

log "=== RESULTS ==="; cat "$RESULTS"
grep -q '^FAIL' "$RESULTS" && { log "SOME CHECKS FAILED"; exit 1; }
log "ALL CHECKS PASSED"

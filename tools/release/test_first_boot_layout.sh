#!/bin/bash
# First-boot layout test in QEMU: boots a FLASH image (unitotem-<date>-amd64-flash.img[.xz], from unitotem/make-flash-image.sh)
# written raw to a 20 GiB virtual disk, once with UEFI (OVMF) and once with legacy BIOS (SeaBIOS), and checks over ssh that
# the first boot created ROOT_B and DATA, mounted DATA, and that unitotem-update repair fills ROOT_B.
# Needs a BUILT flash image (path as the argument), qemu-system-x86_64 (KVM optional), OVMF, sshpass. It does not run in CI.
#   tools/release/test_first_boot_layout.sh FLASH_IMG[.xz] [uefi|bios|both]
# Environment: OTA_PASSWORD (login password of the image, default unitotem), DISK_GIB (default 20), PORT (default 2290),
#   WORK (scratch folder, default work/grow-test/qemu-layout), BOOT_TIMEOUT (seconds, default 300), FILL_TIMEOUT (default 900).
# Only a qemu process of this script and files under WORK are touched; no real disk or device.
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG="${1:?usage: test_first_boot_layout.sh FLASH_IMG[.xz] [uefi|bios|both]}"; MODES="${2:-both}"
DISK_GIB="${DISK_GIB:-20}"; PORT="${PORT:-2290}"; WORK="${WORK:-$DIR/work/grow-test/qemu-layout}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"; FILL_TIMEOUT="${FILL_TIMEOUT:-900}"
source "$DIR/deploy/lib.sh"
for c in qemu-system-x86_64 sshpass sgdisk; do require_cmd "$c"; done
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
[ -f "$IMG" ] || die "flash image not found: $IMG"
mkdir -p "$WORK"
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { failn=$((failn+1)); echo "FAIL: $1"; }
# check DESCRIPTION CMD...   (a local command)
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# rchk DESCRIPTION REMOTE-COMMAND   (a command run in the VM)
rchk() { if qssh "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
qssh() { _sshpass_pw ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=5 root@127.0.0.1 "$@"; }
PIDF="$WORK/qemu.pid"
stop_vm() { if [ -f "$PIDF" ]; then kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; fi; }
trap stop_vm EXIT

RAW="$WORK/flash.img"
case "$IMG" in *.xz) xz -dc "$IMG" > "$RAW" ;; *) cp --sparse=always "$IMG" "$RAW" ;; esac
FLASH_GIB=$(( ($(stat -c %s "$RAW") + 1073741823) / 1073741824 ))

run_mode() {
    local mode=$1 disk="$WORK/disk-$1.img" fw=() kvm=() t=0 lay dump dsz
    echo "=== $mode"
    rm -f "$disk"; truncate -s "${DISK_GIB}G" "$disk"
    dd if="$RAW" of="$disk" bs=1M conv=notrunc,sparse status=none     # what Imager / dd does to a card
    if [ "$mode" = uefi ]; then
        cp "$OVMF_VARS" "$WORK/vars-$mode.fd"
        fw=(-machine q35 -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/vars-$mode.fd")
    else
        fw=(-machine q35)    # SeaBIOS is QEMU's default firmware
    fi
    if [ -w /dev/kvm ]; then kvm=(-enable-kvm -cpu host); else kvm=(-cpu max); fi
    qemu-system-x86_64 -name "layout-$mode" "${kvm[@]}" -smp 4 -m 4096 "${fw[@]}" \
        -drive "file=$disk,if=virtio,format=raw" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${PORT}-:22" -device virtio-net-pci,netdev=n0 \
        -display none -serial "file:$WORK/serial-$mode.log" -pidfile "$PIDF" -daemonize
    until qssh true 2>/dev/null; do
        sleep 5; t=$((t+5)); [ "$t" -lt "$BOOT_TIMEOUT" ] || { bad "$mode: ssh up within ${BOOT_TIMEOUT}s"; stop_vm; return 0; }
    done
    ok "$mode: booted, ssh reachable after ~${t}s"
    lay=$(qssh 'lsblk -bno NAME,SIZE,PARTLABEL,LABEL,FSTYPE,MOUNTPOINT /dev/vda' || true)
    echo "$lay" | sed 's/^/    /'
    chk "$mode: PARTLABEL ROOT_B present" grep -q ROOT_B <<<"$lay"
    chk "$mode: PARTLABEL DATA present" grep -q ' DATA ' <<<"$lay"
    chk "$mode: DATA mounted on /mnt/data" grep -q '/mnt/data' <<<"$lay"
    dsz=$(qssh 'blockdev --getsize64 /dev/disk/by-partlabel/DATA' || echo 0)
    chk "$mode: DATA spans the rest of the disk ($((dsz>>30)) GiB of ${DISK_GIB})" [ "$dsz" -gt $(( (DISK_GIB - FLASH_GIB - 6) * 1073741824 )) ]
    rchk "$mode: sgdisk -v clean" 'sgdisk -v /dev/vda | grep -q "No problems found"'
    dump=$(qssh 'sfdisk -d /dev/vda' || true)
    chk "$mode: no pending-format flag (GPT attribute bit 48) left" bash -c '! grep -q "GUID:48" <<<"$1"' _ "$dump"
    rchk "$mode: /etc overlay mounted" 'grep -q " /etc overlay " /proc/mounts'
    rchk "$mode: ssh host keys persisted on DATA" 'ls /mnt/data/unitotem/ssh-host-keys/ssh_host_ed25519_key'
    # the repair rebuilds ROOT_B from the running slot (UPDATE_AUTOREPAIR=1, started after boot-ok)
    t=0
    until qssh 'unitotem-update --json status | grep -Eq "\"other_version\": *\"[0-9]"' 2>/dev/null; do
        sleep 10; t=$((t+10)); [ "$t" -lt "$FILL_TIMEOUT" ] || break
    done
    if [ "$t" -lt "$FILL_TIMEOUT" ]; then ok "$mode: ROOT_B filled by the automatic repair (~${t}s)"; else bad "$mode: ROOT_B filled within ${FILL_TIMEOUT}s"; fi
    rchk "$mode: ROOT_B mounts and holds a system" 'mkdir -p /tmp/rb && mount -o ro /dev/disk/by-partlabel/ROOT_B /tmp/rb && r=0; test -s /tmp/rb/usr/share/unitotem/release-version || r=1; umount /tmp/rb; exit $r'
    # second boot: nothing left to do
    qssh 'systemctl reboot' >/dev/null 2>&1 || true
    sleep 30; t=0
    until qssh true 2>/dev/null; do sleep 5; t=$((t+5)); [ "$t" -lt "$BOOT_TIMEOUT" ] || break; done
    rchk "$mode: second boot: ssh up, DATA mounted, table clean" 'grep -q " /mnt/data " /proc/mounts && sgdisk -v /dev/vda | grep -q "No problems found" && test "$(sfdisk -d /dev/vda | grep -c "name=")" -ge 4'
    stop_vm
}

case "$MODES" in
    uefi) run_mode uefi ;;
    bios) run_mode bios ;;
    both) run_mode uefi; run_mode bios ;;
    *) die "mode must be uefi, bios or both" ;;
esac
rm -f "$RAW" "$WORK/disk-uefi.img" "$WORK/disk-bios.img" "$WORK/vars-uefi.fd"
echo "RESULT: $pass passed, $failn failed"
[ "$failn" = 0 ]

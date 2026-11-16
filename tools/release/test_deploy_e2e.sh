#!/bin/bash
# Rehearsal of a network deploy, no hardware: an amd64 PC (QEMU/KVM) boots the recovery kernel and initrd of build/amd64/recovery into the OTA
# fallback (open access), remote-deploy.sh deploy writes the image from a privileged container, then the disk boots (UEFI through OVMF, or
# legacy BIOS) and the web UI must answer with the first-access page. Scratch: work/deploy-e2e/. Needs docker, /dev/kvm, qemu, OVMF.
#   tools/release/test_deploy_e2e.sh [uefi|bios] [IMAGE.img.xz]     (default: uefi, the newest deploy/amd64/unitotem-2*-amd64.img.xz)
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FW=${1:-uefi}; IMG=${2:-$(ls -t "$DIR"/deploy/amd64/unitotem-2*-amd64.img.xz 2>/dev/null | head -1)}
W="$DIR/work/deploy-e2e"; mkdir -p "$W/out"
[ -f "$IMG" ] || { echo "no amd64 image (deploy/amd64/unitotem-<date>-amd64.img.xz)"; exit 1; }
[ -e /dev/kvm ] || { echo "no /dev/kvm"; exit 1; }
FB=2372; WEB=8473; DISK="$W/e2e-$FW.img"; ok=0; fail=0
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok=$((ok + 1)); echo "PASS: $n"; else fail=$((fail + 1)); echo "FAIL: $n"; fi; }
cleanup() { systemctl --user stop qemu-e2e-fb qemu-e2e-disk 2>/dev/null; rm -f "$DISK"; }
trap cleanup EXIT

# the initrd of the fallback with the engine of the repository appended (a second cpio archive: the later entry wins)
cp "$DIR/build/amd64/recovery/recovery-initrd-amd64.img" "$W/initrd"
mkdir -p "$W/ov/usr/lib/unitotem"; install -m 755 "$DIR/deploy/script/ota-engine.sh" "$W/ov/usr/lib/unitotem/ota-engine.sh"
( cd "$W/ov" && printf 'usr/lib/unitotem/ota-engine.sh\n' | cpio -o -H newc --quiet --owner=0:0 ) >> "$W/initrd"
docker build -q -f "$DIR/tools/release/Dockerfile.deploy" -t unitotem-deploy-e2e "$DIR/tools/release" >/dev/null || exit 1

qemu_args() {   # MODE
    local mode=$1 vars="$W/ovmf-vars-$FW-$1.fd"; cp -f /usr/share/OVMF/OVMF_VARS_4M.fd "$vars"
    local fw=(-drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on -drive if=pflash,format=raw,unit=1,file="$vars")
    [ "$FW" = bios ] && fw=()
    echo -enable-kvm -cpu host -smp 4 -m 4096 -machine q35 -display none -no-reboot "${fw[@]}" -drive "file=$DISK,if=virtio,format=raw" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$FB-:2222,hostfwd=tcp:127.0.0.1:$WEB-:443" -device virtio-net-pci,netdev=n0 -serial "file:$W/e2e-$FW-$mode.log"
}
rm -f "$DISK"; truncate -s 16G "$DISK"
systemd-run --user --unit=qemu-e2e-fb --collect timeout 1800 qemu-system-x86_64 $(qemu_args fb) -kernel "$DIR/build/amd64/recovery/recovery-vmlinuz-amd64" \
    -initrd "$W/initrd" -append "unitotem.ota=recover console=ttyS0,115200" >/dev/null 2>&1
up=0; for _ in $(seq 1 60); do
    timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$FB && head -c 20 <&3" 2>/dev/null | grep -q dropbear && { up=1; break; }; sleep 4; done
check "the fallback (dropbear) is up" [ "$up" = 1 ]
[ "$up" = 1 ] || { echo "$ok passed, $fail failed"; exit 1; }
docker run --rm --privileged --network host --shm-size=24g -v "$DIR:/repo" -v "$(dirname "$IMG"):/img:ro" -v /dev:/dev \
    -e UNITOTEM_BACKUP_DIR=/repo/work/deploy-e2e/backups unitotem-deploy-e2e \
    bash /repo/deploy/script/remote-deploy.sh deploy 127.0.0.1:$FB --port 9710 --image "/img/$(basename "$IMG")" --yes > "$W/out/e2e-$FW.log" 2>&1; rc=$?
check "remote-deploy.sh deploy finds the fallback, logs in without a password (open) and exits 0" bash -c "[ $rc = 0 ] && grep -q 'Logged in to the fallback as root (open)' $W/out/e2e-$FW.log"
check "the log reaches the reboot into the restored system" grep -q 'Recovery sequence sent' "$W/out/e2e-$FW.log"
systemctl --user stop qemu-e2e-fb 2>/dev/null
systemd-run --user --unit=qemu-e2e-disk --collect timeout 900 qemu-system-x86_64 $(qemu_args disk) >/dev/null 2>&1
code=000; for _ in $(seq 1 90); do code=$(curl -sk -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "https://127.0.0.1:$WEB/login"); case "$code" in 000*) sleep 8 ;; *) break ;; esac; done
check "the deployed system boots ($FW) and the web UI shows the first-access page" bash -c "echo '$code' | grep -q '307 .*/setup'"
echo "$ok passed, $fail failed"; [ "$fail" = 0 ]

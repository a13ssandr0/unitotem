#!/bin/bash
# Does the amd64 OTA environment really come up at a LOW resolution? Boots the built amd64 image in QEMU (UEFI/OVMF, virtio-vga,
# whose native size is far above 640x480) into the OTA entry 'slot-a-recover', twice: with the grub.cfg of the image as built
# (baseline) and with the OTA entries patched the way kiosk/files/grub-ab-entries now generates them, then asks QEMU for a
# screendump (PPM header = real framebuffer size) and compares. Needs no root: the ESP is edited with mtools.
#   test-ota-lowres-amd64.sh IMAGE.img.xz
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; XZ="${1:?image .img.xz}"
W="$DIR/work/lowres"; mkdir -p "$W"; RAW="$W/base.img"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
if [ ! -s "$RAW" ] || [ "$XZ" -nt "$RAW" ]; then echo ">>> unpacking $XZ"; xz -dc "$XZ" | dd of="$RAW" bs=4M conv=sparse status=none; fi
esp_off=$(sfdisk -d "$RAW" | awk -F'[=, ]+' '/start=/ && NR>3 && !d {for(i=1;i<=NF;i++) if($i=="start") {print $(i+1)*512; d=1}}')
echo ">>> ESP at byte $esp_off"
mdir -i "$RAW@@$esp_off" ::unitotem-grub/grub >/dev/null
mcopy -n -i "$RAW@@$esp_off" ::unitotem-grub/grub/grub.cfg "$W/grub.orig"
python3 - "$W/grub.orig" "$W/grub.base" "$W/grub.low" "$DIR/kiosk/files/grub-ab-entries" <<'PY'
import sys,re
orig=open(sys.argv[1]).read()
entries=open(sys.argv[4]).read()
func=entries[entries.index("function unitotem_lowres"):]; func=func[:func.index("\n}\n")+3]
# the real file's patched lines are exactly what grub-mkconfig copies into grub.cfg from the entries file
ent=entries.split("\n")
new_a=[l for l in ent if "label ROOT_A ro quiet nomodeset" in l][0].strip()
old_a=new_a.replace(" nomodeset","")
assert old_a in orig, "grub.cfg as built does not contain the OTA recover line"
base=orig+"\nset default=slot-a-recover\nset timeout=0\n"
low=orig.replace(old_a,"unitotem_lowres\n    "+new_a if False else new_a)
# insert the function call before 'search' of the recover entry
i=low.index(new_a); j=low.rindex("search --no-floppy",0,i)
low=low[:j]+"unitotem_lowres\n    "+low[j:]
low=func+low+"\nset default=slot-a-recover\nset timeout=0\n"
open(sys.argv[2],"w").write(base); open(sys.argv[3],"w").write(low)
PY
run_vm() { # run_vm NAME GRUBCFG -> prints framebuffer size of the screendump after the OTA environment is up
    local name="$1" cfg="$2" img="$W/$1.img"; cp --sparse=always "$RAW" "$img"
    mcopy -o -i "$img@@$esp_off" "$cfg" ::unitotem-grub/grub/grub.cfg
    cp "$OVMF_VARS" "$W/$name.vars"; rm -f "$W/$name.sock" "$W/$name.ppm" "$W/$name.serial"
    qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 2 -m 2048 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" -drive if=pflash,format=raw,file="$W/$name.vars" \
        -drive file="$img",format=raw,if=virtio -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -device virtio-vga -display none -serial "file:$W/$name.serial" -monitor "unix:$W/$name.sock,server,nowait" -pidfile "$W/$name.pid" &
    sleep 2
    local i; for i in $(seq 1 60); do grep -aq "OTA\|ota" "$W/$name.serial" 2>/dev/null && break; sleep 3; done
    sleep 25
    python3 -I - "$W/$name.sock" "$W/$name.ppm" <<'PY'
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(.5); s.recv(4096)
s.send(("screendump %s\n"%sys.argv[2]).encode()); time.sleep(2); s.recv(4096)
PY
    kill -9 "$(cat "$W/$name.pid")" 2>/dev/null || true
    head -c 20 "$W/$name.ppm" | head -2 | tr '\n' ' '; echo " <- $name"
}
run_vm baseline "$W/grub.base"
run_vm lowres "$W/grub.low"

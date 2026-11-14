#!/bin/bash
# Boots a disk image under QEMU/KVM with Secure Boot OVMF (Microsoft keys). Usage: run-vm.sh IMG NAME [extra qemu args]; ssh on 127.0.0.1:2222, serial in NAME.serial.
set -u
W=/nas/build/ubuntu-proto
IMG=$1; NAME=$2; shift 2
cp -f /usr/share/OVMF/OVMF_VARS_4M.ms.fd "$W/$NAME.vars"
exec timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4096 -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$W/$NAME.vars" \
  -drive file="$IMG",format=raw,if=virtio -netdev user,id=n,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n \
  -display none -serial "${SERIAL:-file:$W/$NAME.serial}" -vga std "$@"

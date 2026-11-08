#!/bin/sh
# Loads nouveau when an NVIDIA display device has no driver bound.
# nvidia-kernel-support blacklists nouveau; an explicit modprobe ignores the blacklist.
# The open NVIDIA modules do not drive Pascal and older GPUs, so those stay unbound.
set -u

PCI_DEVICES=${PCI_DEVICES:-/sys/bus/pci/devices}

udevadm settle --timeout=20 || true

unserved=""
for dev in "$PCI_DEVICES"/*; do
    [ -e "$dev" ] || continue
    # vendor 0x10de = NVIDIA
    vendor=$(cat "$dev/vendor" 2>/dev/null) || continue
    [ "$vendor" = 0x10de ] || continue
    # class 0x03xxxx = display controller
    class=$(cat "$dev/class" 2>/dev/null) || continue
    case $class in
        0x03*) ;;
        *) continue ;;
    esac
    # no driver symlink: nothing is bound to the device
    if [ ! -L "$dev/driver" ]; then
        unserved="$unserved ${dev##*/}"
    fi
done

if [ -n "$unserved" ]; then
    if modprobe nouveau; then
        logger -t unitotem-nouveau-fallback "no driver bound to NVIDIA display device(s):$unserved; nouveau loaded"
    else
        logger -t unitotem-nouveau-fallback "no driver bound to NVIDIA display device(s):$unserved; modprobe nouveau failed"
    fi
fi

exit 0

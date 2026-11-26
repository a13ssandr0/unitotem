#!/usr/bin/env bash
# Boot a UniTotem amd64 image in QEMU (OVMF, snapshot disk) and record a screendump timeline.
# Usage: boot-timeline-vm.sh IMAGE.img[.xz] OUTDIR [--seconds N] [--fps F] [--gpu std|virtio|qxl] [--name PREFIX]
# Output: OUTDIR/{frames/,timeline.csv,summary.txt,contact.png,contact-black.png,serial.log,qemu.log}
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd

usage() {
    echo "usage: $0 IMAGE.img[.xz] OUTDIR [--seconds N] [--fps F] [--gpu std|virtio|qxl] [--name PREFIX]" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
IMAGE="$1"; OUT="$2"; shift 2
SECONDS_RUN=90; FPS=5; GPU=virtio; PREFIX="boot-timeline"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds) SECONDS_RUN="${2:-}"; shift 2 ;;
        --fps) FPS="${2:-}"; shift 2 ;;
        --gpu) GPU="${2:-}"; shift 2 ;;
        --name) PREFIX="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -f "$IMAGE" ]] || { echo "no such image: $IMAGE" >&2; exit 1; }
[[ "$SECONDS_RUN" =~ ^[0-9]+$ ]] && (( SECONDS_RUN > 0 && SECONDS_RUN <= 3600 )) || { echo "bad --seconds" >&2; exit 2; }
[[ "$FPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "bad --fps" >&2; exit 2; }
[[ "$PREFIX" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || { echo "bad --name (letters, digits, _ and - only)" >&2; exit 2; }
case "$GPU" in
    std) VGA=(-vga std) ;;
    virtio) VGA=(-vga none -device virtio-vga) ;;
    qxl) VGA=(-vga qxl) ;;
    *) echo "bad --gpu: $GPU" >&2; exit 2 ;;
esac
command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
[[ -r "$OVMF_CODE" && -r "$OVMF_VARS" ]] || { echo "OVMF firmware not found" >&2; exit 1; }

# OUTDIR must be new or empty: nothing is ever deleted.
if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" ]] || { echo "OUTDIR exists and is not a directory: $OUT" >&2; exit 1; }
    if [[ -n "$(ls -A -- "$OUT")" ]]; then
        echo "OUTDIR is not empty, refusing: $OUT" >&2; exit 1
    fi
else
    mkdir -p -- "$OUT"
fi
OUT="$(cd -- "$OUT" && pwd)"
mkdir -p -- "$OUT/frames"

QPID=""
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n "$QPID" ]] && kill -0 "$QPID" 2>/dev/null; then
        kill -TERM "$QPID" 2>/dev/null || true
        for _ in $(seq 1 50); do
            kill -0 "$QPID" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$QPID" 2>/dev/null || true
    fi
    [[ -n "$QPID" ]] && wait "$QPID" 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Disk: decompress .xz to OUTDIR/image.img (the original is only read).
if [[ "$IMAGE" == *.xz ]]; then
    NEED=$(xz --robot --list -- "$IMAGE" | awk -F'\t' '$1=="totals"{print $5}')
    AVAIL=$(df --output=avail -B1 -- "$OUT" | tail -1)
    if [[ -n "$NEED" && "$AVAIL" -lt "$NEED" ]]; then
        echo "not enough space in $OUT: need $NEED bytes, have $AVAIL" >&2; exit 1
    fi
    echo "decompressing $(basename -- "$IMAGE") to $OUT/image.img" >&2
    xz -dc -- "$IMAGE" > "$OUT/image.img"
    DISK="$OUT/image.img"
else
    DISK="$(cd -- "$(dirname -- "$IMAGE")" && pwd)/$(basename -- "$IMAGE")"
fi
cp -- "$OVMF_VARS" "$OUT/OVMF_VARS.fd"

# Launch the VM; only this PID is ever signalled.
T0_MS=$(date +%s%3N)
qemu-system-x86_64 -name "$PREFIX-$$" -machine q35 -enable-kvm -cpu host -smp 2 -m 3072 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OUT/OVMF_VARS.fd" \
    -snapshot -drive file="$DISK",format=raw,if=virtio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    "${VGA[@]}" -display none -monitor none \
    -serial "file:$OUT/serial.log" \
    -qmp "unix:$OUT/qmp.sock,server=on,wait=off" \
    >"$OUT/qemu.log" 2>&1 &
QPID=$!
echo "qemu pid $QPID started, timeline ${SECONDS_RUN}s at ${FPS} fps" >&2

python3 -I "$HERE/boot_timeline_vm.py" --out "$OUT" --sock "$OUT/qmp.sock" \
    --t0-ms "$T0_MS" --seconds "$SECONDS_RUN" --fps "$FPS"

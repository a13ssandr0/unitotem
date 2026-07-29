#!/bin/bash
# Shared host-side helpers for deploy/remote-deploy.sh and deploy/build-flasher.sh.
# Not meant to be executed directly.

log()  { echo ">>> $*"; }
warn() { echo "!!! $*" >&2; }
die()  { echo "*** $*" >&2; exit 1; }

require_cmd() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "Comandi mancanti sull'host: ${missing[*]}"
}

# Partition device suffix, mirrors iso/installer.sh's pdev():
# /dev/sda -> /dev/sda1 ; /dev/nvme0n1|/dev/mmcblk0 -> ...p1
pdev() {
    local disk="$1" num="$2"
    if [[ "$disk" =~ (nvme|mmcblk) ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# Parse a size like "12G", "512M", "838415552" (bytes, optionally with a unit
# suffix as used by truncate/parted) into raw bytes.
size_to_bytes() {
    local s="$1" num unit
    if [[ "$s" =~ ^([0-9]+)([KMGTkmgt]?)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]^^}"
        case "$unit" in
            K) echo $((num * 1024)) ;;
            M) echo $((num * 1024 * 1024)) ;;
            G) echo $((num * 1024 * 1024 * 1024)) ;;
            T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
            *) echo "$num" ;;
        esac
    else
        die "Dimensione non riconosciuta: $s"
    fi
}

bytes_human() {
    local b=$1
    awk -v b="$b" 'BEGIN {
        split("B K M G T", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf "%.1f%s", b, u[i]
    }'
}

# Per-arch on-disk layout produced by kiosk/stage3-image.sh. Kept here as the
# single source of truth for the host-side tooling (the target-side flasher
# gets the same facts through the pushed manifest, see build_deploy_manifest).
layout_data_partnum() { [ "$1" = "arm64" ] && echo 3 || echo 4; }
layout_has_esp()      { [ "$1" = "arm64" ] && echo 0 || echo 1; }
layout_esp_partnum()  { echo 1; }

# ssh/scp wrappers: consistent options, and always operate on $TARGET_USERHOST.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

ssh_t() {
    ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "$@"
}

# Run a shell snippet on the target, feeding it on stdin (avoids quoting hell
# for anything longer than a one-liner).
ssh_script() {
    ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "sh -s"
}

scp_t() {
    scp -o BatchMode=yes -o ConnectTimeout=10 "$@"
}

# Build the small KEY=VALUE manifest describing one .img.xz|.img.zst artifact.
# Pushed to the target next to the image (ram/part modes) and streamed as a
# text header in front of the image bytes (net mode) - see
# deploy/flasher/unitotem-flash for the parser.
build_deploy_manifest() {
    local image="$1" arch="$2"
    local comp raw_size comp_size comp_sha256

    case "$image" in
        *.img.xz)  comp=xz ;;
        *.img.zst) comp=zstd ;;
        *) die "Formato immagine non riconosciuto (atteso .img.xz o .img.zst): $image" ;;
    esac

    comp_size=$(stat -c%s "$image")
    comp_sha256=$(sha256sum "$image" | cut -d' ' -f1)

    if [ "$comp" = xz ]; then
        raw_size=$(xz -l --robot "$image" | awk -F'\t' '$1=="totals"{print $5}')
    else
        raw_size=$(zstd -l "$image" 2>/dev/null | awk 'NR==2{printf "%d", $3*1024*1024}')
    fi
    [ -n "$raw_size" ] && [ "$raw_size" -gt 0 ] 2>/dev/null \
        || die "Impossibile determinare la dimensione decompressa di $image"

    cat <<EOF
UNITOTEM_ARCH=${arch}
UNITOTEM_COMP=${comp}
UNITOTEM_RAW_SIZE=${raw_size}
UNITOTEM_COMP_SIZE=${comp_size}
UNITOTEM_COMP_SHA256=${comp_sha256}
UNITOTEM_IMAGE_NAME=$(basename "$image")
UNITOTEM_DATA_PART=$(layout_data_partnum "$arch")
UNITOTEM_HAS_ESP=$(layout_has_esp "$arch")
EOF
}

#!/bin/bash
# Lab driver: runs the REAL run_ota_sequence()/populate_bootfs_step() of deploy/remote-deploy.sh against a target that is
# already in the OTA environment (the same steps as the `recover` subcommand), for an amd64/UEFI A-B parts set,
# with --secure-boot shim. Usage: recover-driver.sh HOST DISK_BYID PARTS_DIR
# Fallback credentials come from the environment (deploy/lib.sh, ota_auth_for): OTA_FALLBACK_KEY, or
# OTA_FALLBACK_USER with OTA_FALLBACK_PASSWORD, or OTA_FALLBACK_OPEN=1. The per-target key is used when it exists.
set -euo pipefail
DIR=$(cd "$(dirname "$0")/../.." && pwd)
source "$DIR/deploy/lib.sh"
HOST="$1"; DISK_BYID="$2"; OPT_PARTS="$3"
ARCH=amd64 FIRMWARE=uefi TRYBOOT_CAPABLE=0 SB_MODE=shim OPT_PORT=9700 OPT_WIPE_DATA=1 OPT_DEBUG=0 OPT_YES=1
declare -A P; P[HAVE_UNITOTEM]=0; P[HAVE_DATA]=0; P[SSHCLIENT]=none; P[NETLINK]=wired; P[NETMODE]=dhcp
M="$OPT_PARTS/parts.manifest"
P_DATA_PART=$(awk -F= '/^UNITOTEM_DATA_PART=/{print $2}' "$M")
P_BOOTFS_PART=$(awk -F= '/^UNITOTEM_BOOTFS_PART=/{print $2}' "$M")
part_num_for_label() { awk -F= -v want="$1" '/^UNITOTEM_PART=/{n=$2} /^UNITOTEM_PART_LABEL=/{if($2==want){print n; exit}}' "$M"; }
P_LAYOUT=$(awk -F= '/^UNITOTEM_LAYOUT=/{print $2; exit}' "$M"); P_LAYOUT="${P_LAYOUT:-1}"
[ "$P_LAYOUT" = 2 ] && P_ROOT_PART=$(part_num_for_label ROOT_A) || P_ROOT_PART=$(part_num_for_label ROOT)
P_BOOT_PART=$(part_num_for_label BOOT)
P_BOOTFS_VOLID=$(awk -F= '/^UNITOTEM_PART_VOLID=/{print $2; exit}' "$M")
# pull the two functions out of the real script (no copy to maintain)
eval "$(awk '/^populate_bootfs_step\(\) \{/,/^}/' "$DIR/deploy/remote-deploy.sh")"
eval "$(awk '/^run_ota_sequence\(\) \{/,/^}/' "$DIR/deploy/remote-deploy.sh")"
log "layout=$P_LAYOUT root=$P_ROOT_PART bootfs=$P_BOOTFS_PART data=$P_DATA_PART boot=$P_BOOT_PART"
run_ota_sequence "$HOST" "$DISK_BYID"

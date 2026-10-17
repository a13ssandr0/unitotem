#!/bin/bash
# SD wear guard for the real test Pi: every 30 s read the kernel's sectors-written counter of mmcblk0 (over the deploy/lib.sh ssh helper).
# If more than LIMIT_MIB_PER_MIN is written in a minute (default 300) it stops the test load units (pwr-writer and any unit named
# *-testload.service) and logs "SDGUARD" in work/pi-test/STATE.md; it logs a heartbeat line every 10 minutes. Run it detached next to ANY job that writes on the Pi:
#   (setsid nohup tools/pi-sd-guard.sh 21600 > /dev/null 2>&1 &)      # duration in seconds
cd "$(dirname "$0")/.." || exit 1
source deploy/lib.sh
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
Q() { _sshpass ssh -n "${SSH_OPTS[@]}" "${SSHO[@]}" "root@${PI_IP:-<pi-host>}" "$@"; }
LIMIT=${LIMIT_MIB_PER_MIN:-300}; END=$(( $(date +%s) + ${1:-3600} )); prev=""; pt=0; n=0
while [ "$(date +%s)" -lt "$END" ]; do
  w=$(Q "awk '{print \$7}' /sys/block/mmcblk0/stat" 2>/dev/null); t=$(date +%s)
  if [ -n "$w" ] && [ -n "$prev" ] && [ "$w" -ge "$prev" ]; then
    rate=$(( (w - prev) * 512 / 1048576 * 60 / (t - pt) ))
    if [ "$rate" -gt "$LIMIT" ]; then
      Q "systemctl stop pwr-writer; for u in \$(systemctl list-units --no-legend '*-testload.service' | cut -d' ' -f1); do systemctl stop \$u; done" >/dev/null 2>&1
      echo "SDGUARD $(date +%T) wrote ${rate} MiB/min (> ${LIMIT}): stopped the test load units" >> work/pi-test/STATE.md
    fi
    n=$((n+1)); [ $((n % 20)) = 0 ] && echo "SDGUARD $(date +%T) heartbeat: ${rate} MiB/min" >> work/pi-test/STATE.md
  fi
  [ -n "$w" ] && { prev=$w; pt=$t; }
  sleep 30
done

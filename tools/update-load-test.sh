#!/bin/bash
# Measures what an update does to a device: samples load, CPU, SD counters and dirty pages on the Pi every second and probes
# the web interface and SSH latency from the dev PC every 2 s while `fetch --force` runs. Usage: HOST=<address> tools/update-load-test.sh NAME [base|tune|bfq|cpu]
# base = the updater as it is; tune = capped dirty pages; bfq = bfq and capped dirty pages; cpu = download and decompress only (needs ASSET_URL), nothing is written.
# Key login as root (BatchMode). Output work/update-load/NAME.{pi,probe,fetch}.log; analyse with tools/update-load-analyze.py NAME
cd "$(dirname "$0")/.." || exit 1
NAME=${1:?name}; MODE=${2:-base}; HOST=${HOST:?HOST=<device address>}
D=work/update-load; mkdir -p $D
O="-o BatchMode=yes -o PreferredAuthentications=publickey -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
R() { SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS ssh $O root@$HOST "$@"; }
echo "start $(date +%T) mode=$MODE" > $D/$NAME.fetch.log
R 'cat /usr/share/unitotem/release-version; awk "{print \$7}" /sys/block/mmcblk0/stat' >> $D/$NAME.fetch.log
if [ "$MODE" = tune ] || [ "$MODE" = bfq ]; then
  [ "$MODE" = bfq ] && R 'cat /sys/block/mmcblk0/queue/scheduler > /run/sched-before.txt; echo bfq > /sys/block/mmcblk0/queue/scheduler; cat /sys/block/mmcblk0/queue/scheduler' >> $D/$NAME.fetch.log
  R 'rm -f /run/dstate.log; for k in dirty_bytes dirty_background_bytes dirty_ratio dirty_background_ratio; do echo "$k=$(cat /proc/sys/vm/$k)" ; done > /run/vm-before.txt; sysctl -q -w vm.dirty_background_bytes=16777216 vm.dirty_bytes=67108864; cat /proc/sys/vm/dirty_bytes' >> $D/$NAME.fetch.log
fi
# Pi side sampler (one ssh session, bounded)
SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS timeout 900 ssh $O root@$HOST 'while :; do echo "$(date +%s.%N) $(cut -d" " -f1 /proc/loadavg) $(awk "NR==1{print \$2+\$3+\$4,\$5,\$6,\$8}" /proc/stat) $(awk "\$3==\"mmcblk0\"{print \$4,\$6,\$8,\$10,\$12,\$13}" /proc/diskstats) $(awk "/^Dirty|^Writeback:/{printf \$2\" \"}" /proc/meminfo) $(a=$(date +%s%N); dd if=/dev/mmcblk0 of=/dev/null bs=4k count=1 skip=$((RANDOM*8)) iflag=direct 2>/dev/null; b=$(date +%s%N); echo $(( (b-a)/1000000 )))"; ps -eLo comm,stat,wchan:24 | awk "\$2 ~ /^D/{c[\$1\":\"\$3]++} END{for(k in c) printf \"%s=%d \", k, c[k]; print \"\"}" >> /run/dstate.log; sleep 1; done' > $D/$NAME.pi.log 2>&1 &
SAMP=$!
# probes from the dev PC
( while :; do
    t=$(date +%s.%N)
    w=$(curl -sk -m 15 -o /dev/null -w '%{time_total}' https://$HOST/login 2>/dev/null || echo fail)
    s0=$(date +%s.%N)
    SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS ssh $O root@$HOST true 2>/dev/null && s=$(echo "$(date +%s.%N) - $s0" | bc) || s=fail
    echo "$t web=$w ssh=$s"
    sleep 1
  done ) > $D/$NAME.probe.log 2>&1 &
PROBE=$!
sleep 15   # quiet baseline
echo "fetch start $(date +%s.%N)" >> $D/$NAME.fetch.log
if [ "$MODE" = cpu ]; then
  # CPU only: download and decompress the root asset like the updater does (nice 19, idle I/O class), write nothing
  : "${ASSET_URL:?ASSET_URL=<root asset URL>}"
  R "systemd-run --unit=cpu-only-test --collect --quiet -p Nice=19 -p IOSchedulingClass=idle -p RuntimeMaxSec=300 sh -c 'curl -sL \"${ASSET_URL}\" | xz -dc > /dev/null'" >> $D/$NAME.fetch.log
  sleep 3
  for i in $(seq 1 120); do
    r=$(R 'systemctl is-active cpu-only-test' 2>/dev/null)
    [ "$r" != active ] && break
    sleep 3
  done
else
  R 'unitotem-update --json fetch --force' >> $D/$NAME.fetch.log
  for i in $(seq 1 400); do
    r=$(R 'unitotem-update --json status' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["op"])' 2>/dev/null)
    [ "$r" = None ] && break
    sleep 3
  done
fi
echo "fetch end $(date +%s.%N)" >> $D/$NAME.fetch.log
R 'unitotem-update --json status | cut -c1-300; awk "{print \$7}" /sys/block/mmcblk0/stat' >> $D/$NAME.fetch.log
sleep 15   # quiet tail
if [ "$MODE" = tune ] || [ "$MODE" = bfq ]; then
  [ "$MODE" = bfq ] && R 'echo mq-deadline > /sys/block/mmcblk0/queue/scheduler; cat /sys/block/mmcblk0/queue/scheduler' >> $D/$NAME.fetch.log
  R 'tail -n 400 /run/dstate.log | sort | uniq -c | sort -rn | head -8' >> $D/$NAME.fetch.log
  R '. /run/vm-before.txt 2>/dev/null; sysctl -q -w vm.dirty_bytes=0 vm.dirty_background_bytes=0 vm.dirty_ratio=20 vm.dirty_background_ratio=10; for k in dirty_bytes dirty_ratio dirty_background_ratio; do echo "$k=$(cat /proc/sys/vm/$k)"; done' >> $D/$NAME.fetch.log
fi
kill $PROBE $SAMP 2>/dev/null
echo "done $(date +%T)" >> $D/$NAME.fetch.log
echo done > $D/$NAME.done

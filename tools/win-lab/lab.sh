#!/bin/bash
# Helpers for the Windows 11 lab VM (libvirt domain win11-lab, a clone: the user's win11 is never touched).
#   lab.sh start|stop|revert [SNAP]|snap NAME|ssh 'powershell command'|wait|shot FILE.png|list
DOM=win11-lab; V() { LC_ALL=C virsh -c qemu:///system "$@"; }
HERE=$(cd "$(dirname "$0")" && pwd)
ip() { V domifaddr $DOM --source lease 2>/dev/null | awk '/ipv4/{sub("/.*","",$4); print $4; exit}'; }
wssh() { SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS ssh -n -i "$HERE/id_lab" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 lab@"$(ip)" "$@"; }
case "$1" in
  start) V start $DOM ;;
  wait) for i in $(seq 1 90); do wssh true 2>/dev/null && { echo "ssh up after $((i*4))s ($(ip))"; exit 0; }; sleep 4; done; echo "ssh not up"; exit 1 ;;
  stop) wssh 'Stop-Computer -Force' 2>/dev/null; for i in $(seq 1 45); do [ "$(V domstate $DOM)" = "shut off" ] && exit 0; sleep 4; done; V destroy $DOM; echo "forced off" ;;
  revert) V snapshot-revert $DOM "${2:-base-nvram}" ;;
  snap) V snapshot-create-as $DOM "$2" "${3:-lab snapshot}" ;;
  list) V snapshot-list $DOM ;;
  put) SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS scp -i "$HERE/id_lab" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$2" lab@"$(ip)":"${3:-C:/Users/lab/}" ;;
  ssh) shift; wssh "$@" ;;
  shot) t=$(mktemp --suffix=.ppm) && V screenshot $DOM "$t" >/dev/null && ffmpeg -hide_banner -loglevel error -y -i "$t" -vf scale=960:-1 "$2"; rm -f "$t" ;;
  *) echo "usage: lab.sh start|wait|stop|revert [SNAP]|snap NAME|list|ssh CMD|put LOCAL [REMOTE]|shot FILE.png" >&2; exit 2 ;;
esac

#!/bin/bash
# serialcap.sh LOGFILE SECONDS : capture the lab VM's serial console (ttyS0 pty) into LOGFILE, detached-friendly
exec timeout "${2:-600}" script -qfc "virsh -c qemu:///system console win11-lab --force" "$1" < /dev/null

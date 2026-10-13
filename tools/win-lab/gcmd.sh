#!/bin/bash
# gcmd.sh 'grub command' [shotfile] : type a command at the GRUB prompt (US layout), Enter, screenshot
D=$(dirname "$0"); python3 "$D/winkeys.py" win11-lab ustext "$1"; python3 "$D/winkeys.py" win11-lab key KEY_ENTER; sleep 2; [ -n "$2" ] && python3 "$D/winkeys.py" win11-lab shot "$2"

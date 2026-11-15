#!/bin/sh
# Wrapper of build-recovery-initrd.py: native build of the resident OTA fallback (see that file for options).
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
exec python3 -I "${dir}/build-recovery-initrd.py" "$@"

#!/bin/bash
# Test of ota_auth_resolve (deploy/script/lib.sh): how deploy logs in to a fallback by itself. A dropbear started like the fallback's (-T 3 -j -k,
# -B only when open) runs in a container; the cases are: your key ~/.ssh/id_ed25519, another key (not tried), the open fallback, a password typed on the
# terminal, a wrong password, and no terminal at all. Nothing on the host is touched.
#   tools/release/test_ota_auth.sh
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
docker build -q -f "${DIR}/tools/release/Dockerfile.deploy" -t unitotem-deploy-e2e "${DIR}/tools/release" >/dev/null
docker run --rm -v "${DIR}:/repo:ro" unitotem-deploy-e2e bash /repo/tools/release/test_ota_auth_inside.sh

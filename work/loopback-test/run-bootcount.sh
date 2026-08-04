#!/bin/bash
# Driver per inside-bootcount.sh (PLAN.md §11.5 livello 4).
# Nessun parts set richiesto: questo harness costruisce il proprio disco
# minimo, perche' cmd_init_premount guarda solo le label FIRMWARE e ROOT e non
# legge nulla dal contenuto di un'immagine.
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "${DIR}/work/loopback-test/scratch-bootcount"

# --platform esplicito: la cache locale puo' contenere il debian:bookworm
# arm64 tirato giu' da run-arm64.sh, e questo harness non ha motivo di girare
# sotto emulazione (cmd_init_premount non ha rami arch-specifici).
docker run --rm --privileged --platform linux/amd64 \
    -v "${DIR}:/repo:ro" \
    -v "${DIR}/work/loopback-test:/work/driver:ro" \
    -v "${DIR}/work/loopback-test/scratch-bootcount:/work" \
    --workdir /work \
    debian:bookworm \
    bash /work/driver/inside-bootcount.sh

#!/bin/bash
# Encrypted backup of the release signing keys (default dir: ~/.config/unitotem-release).
#
#   tools/release/backup-keys.sh backup  OUT.enc      # asks for a passphrase twice
#   tools/release/backup-keys.sh verify  OUT.enc      # decrypts to memory, checks the keys still sign/verify
#   tools/release/backup-keys.sh restore OUT.enc DIR  # unpacks into DIR (refuses to overwrite)
#
# The passphrase is typed by the person running this; nothing here stores or generates it. Keep the .enc
# in at least three places that do not share a failure with this PC (password manager attachment, offline
# disk/USB elsewhere, printed copy of the base64 text), and the passphrase apart from them.
set -euo pipefail
KEYDIR="${UNITOTEM_KEYDIR:-$HOME/.config/unitotem-release}"
ENC=(openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt)

case "${1:-}" in
backup)
    out="${2:?uso: backup OUT.enc}"; [ ! -e "$out" ] || { echo "$out esiste gia'" >&2; exit 1; }
    tar -C "$KEYDIR" -cf - root.key root.pub release.key release.pub keys.json keys.json.sig | "${ENC[@]}" -out "$out"
    chmod 600 "$out"; echo "scritto $out ($(stat -c %s "$out") byte). Ora: verify, poi copie in 3 posti."
    ;;
verify)
    in="${2:?uso: verify IN.enc}"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    "${ENC[@]}" -d -in "$in" | tar -C "$tmp" -xf -
    echo probe > "$tmp/p"
    for k in root release; do
        openssl pkeyutl -sign -inkey "$tmp/$k.key" -rawin -in "$tmp/p" -out "$tmp/p.sig"
        openssl pkeyutl -verify -pubin -inkey "$tmp/$k.pub" -rawin -in "$tmp/p" -sigfile "$tmp/p.sig" >/dev/null
        cmp -s <(openssl pkey -in "$tmp/$k.key" -pubout) "$tmp/$k.pub" || { echo "$k: pubblica non corrisponde" >&2; exit 1; }
        echo "$k: chiave privata valida e coerente con la pubblica"
    done
    cmp -s "$tmp/root.pub" "$(dirname "$0")/../../unitotem/files/update-root.pub" \
        && echo "root.pub coincide con quella nell'immagine (unitotem/files/update-root.pub)" \
        || echo "ATTENZIONE: root.pub del backup diversa da unitotem/files/update-root.pub" >&2
    ;;
restore)
    in="${2:?uso: restore IN.enc DIR}"; dir="${3:?uso: restore IN.enc DIR}"
    [ ! -e "$dir" ] || { echo "$dir esiste gia'" >&2; exit 1; }
    mkdir -m 700 -p "$dir"; "${ENC[@]}" -d -in "$in" | tar -C "$dir" -xf -; echo "ripristinato in $dir"
    ;;
*) sed -n 2,11p "$0"; exit 2 ;;
esac

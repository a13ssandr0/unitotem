#!/bin/bash
# Encrypted backup of the release signing keys (default dir: ~/.config/unitotem-release).
#
#   tools/release/backup-keys.sh backup  OUT.enc      # asks for a passphrase twice
#   tools/release/backup-keys.sh verify  OUT.enc      # decrypts to memory, checks the keys still sign/verify
#   tools/release/backup-keys.sh restore OUT.enc DIR  # unpacks into DIR (refuses to overwrite)
#
# The passphrase is typed by the operator; nothing here stores or generates it. Keep the .enc in at least three
# places that do not share a failure with this PC, and the passphrase apart from them.
set -euo pipefail
KEYDIR="${UNITOTEM_KEYDIR:-$HOME/.config/unitotem-release}"
ENC=(openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt)

case "${1:-}" in
backup)
    out="${2:?usage: backup OUT.enc}"; [ ! -e "$out" ] || { echo "$out already exists" >&2; exit 1; }
    tar -C "$KEYDIR" -cf - root.key root.pub release.key release.pub keys.json keys.json.sig | "${ENC[@]}" -out "$out"
    chmod 600 "$out"; echo "wrote $out ($(stat -c %s "$out") bytes). Next: verify, then copy to 3 places."
    ;;
verify)
    in="${2:?usage: verify IN.enc}"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    "${ENC[@]}" -d -in "$in" | tar -C "$tmp" -xf -
    echo probe > "$tmp/p"
    for k in root release; do
        openssl pkeyutl -sign -inkey "$tmp/$k.key" -rawin -in "$tmp/p" -out "$tmp/p.sig"
        openssl pkeyutl -verify -pubin -inkey "$tmp/$k.pub" -rawin -in "$tmp/p" -sigfile "$tmp/p.sig" >/dev/null
        cmp -s <(openssl pkey -in "$tmp/$k.key" -pubout) "$tmp/$k.pub" || { echo "$k: public key does not match" >&2; exit 1; }
        echo "$k: private key valid and matches the public key"
    done
    cmp -s "$tmp/root.pub" "$(dirname "$0")/../../unitotem/files/update-root.pub" \
        && echo "root.pub matches the one in the image (unitotem/files/update-root.pub)" \
        || echo "WARNING: the backup root.pub differs from unitotem/files/update-root.pub" >&2
    ;;
restore)
    in="${2:?usage: restore IN.enc DIR}"; dir="${3:?usage: restore IN.enc DIR}"
    [ ! -e "$dir" ] || { echo "$dir already exists" >&2; exit 1; }
    mkdir -m 700 -p "$dir"; "${ENC[@]}" -d -in "$in" | tar -C "$dir" -xf -; echo "restored into $dir"
    ;;
*) sed -n 2,11p "$0"; exit 2 ;;
esac

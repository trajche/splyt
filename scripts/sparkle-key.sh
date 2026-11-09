#!/bin/bash
# Creates the Ed25519 key that signs Splyt updates, once.
#
# - The private key goes to the login keychain (backup) and to the GitHub
#   secret SPARKLE_ED_PRIVATE_KEY (used by the Release workflow). It is never
#   printed or left on disk.
# - The public key is written into App/Info.plist as SUPublicEDKey.
#
# Installed copies only accept updates signed by the key they carry, so losing
# the private key means users must reinstall by hand. Rerunning refuses to
# replace an existing key unless --replace is given.
set -euo pipefail

cd "$(dirname "$0")/.."

REPO=${SPLYT_REPO:-trajche/splyt}
SERVICE=com.amplify2.splyt.sparkle
ACCOUNT=sparkle-ed25519
PLIST=App/Info.plist
OPENSSL=$(command -v /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl | head -1)

fail() {
    echo "error: $*" >&2
    exit 1
}

"$OPENSSL" version | grep -q '^OpenSSL 3' || fail "OpenSSL 3 is required: brew install openssl@3"
gh auth status >/dev/null 2>&1 || fail "run gh auth login first"

existing=$(plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null || true)
if [[ -n $existing && ${1:-} != --replace ]]; then
    fail "$PLIST already has a key. Installed copies only trust that key; pass --replace to start over anyway"
fi

umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/key.pem"
PUBLIC=$("$OPENSSL" pkey -in "$WORK/key.pem" -pubout -outform DER | tail -c 32 | base64)

security add-generic-password -U -a "$ACCOUNT" -s "$SERVICE" \
    -l "Splyt update signing key" -w "$(base64 -i "$WORK/key.pem")"
echo "Saved the private key to the login keychain ($SERVICE)"

gh secret set SPARKLE_ED_PRIVATE_KEY --repo "$REPO" <"$WORK/key.pem" >/dev/null
echo "Set SPARKLE_ED_PRIVATE_KEY on $REPO"

plutil -replace SUPublicEDKey -string "$PUBLIC" "$PLIST"
echo "Wrote SUPublicEDKey $PUBLIC to $PLIST; commit it"

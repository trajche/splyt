#!/bin/bash
# Uploads everything the Release workflow needs to sign and notarize as GitHub
# Actions secrets. Nothing secret is printed or left on disk.
#
#   scripts/github-secrets.sh <AuthKey_KEYID.p8> [issuer id]
#   scripts/github-secrets.sh <AuthKey_KEYID.p8> [issuer id] --p12 <identity.p12>
#
# The .p8 is an App Store Connect API key (Users and Access > Integrations), the
# same one given to `notarytool store-credentials`. Its key ID is read from the
# file name; the issuer ID is asked for if not given.
#
# Without --p12, the Developer ID Application identity that the "Splyt Developer
# ID" profile names is exported from the login keychain; macOS asks to allow the
# export, once per identity in the keychain. Only that one identity is uploaded.
# With --p12, that file is uploaded instead and its password is asked for.
set -euo pipefail

cd "$(dirname "$0")/.."

REPO=${SPLYT_REPO:-trajche/splyt}
TEAM=A4XZSTY453
APP_PROFILE="Splyt Developer ID"
EXT_PROFILE="Splyt Proxy Developer ID"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
OPENSSL=/usr/bin/openssl # LibreSSL: reads and writes the PKCS#12 that macOS uses

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ $# -ge 1 ]] || fail "usage: $0 <AuthKey_KEYID.p8> [issuer id] [--p12 <identity.p12>]"
NOTARY_KEY=$1
shift
ISSUER=""
P12=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --p12) P12=${2:?--p12 needs a file}; shift 2 ;;
        *) ISSUER=$1; shift ;;
    esac
done
[[ -f $NOTARY_KEY ]] || fail "$NOTARY_KEY not found"
KEY_ID=$(basename "$NOTARY_KEY" | sed -n 's/^AuthKey_\([A-Z0-9]*\)\.p8$/\1/p')
[[ -n $KEY_ID ]] || fail "expected a file named AuthKey_<KEYID>.p8"
if [[ -z $ISSUER ]]; then
    read -r -p "App Store Connect issuer ID: " ISSUER
fi
[[ -n $ISSUER ]] || fail "issuer ID is required"
command -v gh >/dev/null || fail "gh is required"
gh auth status >/dev/null 2>&1 || fail "run gh auth login first"

umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Finds an installed profile by name; scripts/release.sh installs them there.
profile_named() {
    local name=$1 file
    for file in "$PROFILES"/*.provisionprofile; do
        [[ -f $file ]] || continue
        security cms -D -i "$file" >"$WORK/profile.plist" 2>/dev/null || continue
        if [[ $(plutil -extract Name raw "$WORK/profile.plist") == "$name" ]]; then
            echo "$file"
            return
        fi
    done
    fail "no installed profile named \"$name\"; run scripts/release.sh once first"
}

APP_PROFILE_FILE=$(profile_named "$APP_PROFILE")
EXT_PROFILE_FILE=$(profile_named "$EXT_PROFILE")

P12_PASSWORD=$($OPENSSL rand -base64 24)
if [[ -n $P12 ]]; then
    [[ -f $P12 ]] || fail "$P12 not found"
    read -r -s -p "Password for $P12: " given
    echo
    $OPENSSL pkcs12 -in "$P12" -passin fd:3 -nodes -out "$WORK/all.pem" 3<<<"$given" \
        || fail "could not open $P12 with that password"
else
    # The certificates the app profile accepts, as SHA-1 fingerprints.
    security cms -D -i "$APP_PROFILE_FILE" >"$WORK/profile.plist"
    : >"$WORK/allowed"
    index=0
    while encoded=$(plutil -extract "DeveloperCertificates.$index" raw "$WORK/profile.plist" 2>/dev/null); do
        base64 -D <<<"$encoded" | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F >>"$WORK/allowed"
        index=$((index + 1))
    done

    echo "Exporting signing identities from the login keychain; allow the export when asked."
    export_password=$($OPENSSL rand -base64 24)
    security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 \
        -P "$export_password" -o "$WORK/all.p12" >/dev/null
    $OPENSSL pkcs12 -in "$WORK/all.p12" -passin fd:3 -nodes -out "$WORK/all.pem" 3<<<"$export_password"
fi

# Split the PEM into one file per block, then pick the Developer ID certificate the
# profile accepts and the private key that belongs to it.
awk -v dir="$WORK" '
    /-----BEGIN / { n++; file = sprintf("%s/block%03d.pem", dir, n) }
    file { print > file }
    /-----END / { close(file); file = "" }
' "$WORK/all.pem"

CERT=""
for block in "$WORK"/block*.pem; do
    grep -q "BEGIN CERTIFICATE" "$block" || continue
    subject=$($OPENSSL x509 -in "$block" -noout -subject)
    [[ $subject == *"Developer ID Application"* && $subject == *"$TEAM"* ]] || continue
    if [[ -z $P12 ]]; then
        sha1=$($OPENSSL x509 -in "$block" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
        grep -qxF "$sha1" "$WORK/allowed" || continue
    fi
    $OPENSSL x509 -in "$block" -noout -checkend 0 >/dev/null || continue
    CERT=$block
    break
done
[[ -n $CERT ]] || fail "no valid Developer ID Application certificate for $TEAM that \"$APP_PROFILE\" accepts"
$OPENSSL x509 -in "$CERT" -noout -pubkey >"$WORK/cert.pub"

KEY=""
for block in "$WORK"/block*.pem; do
    grep -q "PRIVATE KEY" "$block" || continue
    $OPENSSL pkey -in "$block" -pubout 2>/dev/null | cmp -s - "$WORK/cert.pub" || continue
    KEY=$block
    break
done
[[ -n $KEY ]] || fail "the private key for that certificate was not exported"

$OPENSSL pkcs12 -export -in "$CERT" -inkey "$KEY" -name "Splyt Developer ID" \
    -passout fd:3 -out "$WORK/identity.p12" 3<<<"$P12_PASSWORD"
echo "Certificate: $($OPENSSL x509 -in "$CERT" -noout -subject | sed 's/^subject= *//'), expires $($OPENSSL x509 -in "$CERT" -noout -enddate | cut -d= -f2)"

set_secret() {
    gh secret set "$1" --repo "$REPO" >/dev/null
    echo "Set $1"
}

base64 -i "$WORK/identity.p12" | set_secret MACOS_CERTIFICATE_P12
printf '%s' "$P12_PASSWORD" | set_secret MACOS_CERTIFICATE_PASSWORD
base64 -i "$APP_PROFILE_FILE" | set_secret SPLYT_APP_PROFILE
base64 -i "$EXT_PROFILE_FILE" | set_secret SPLYT_PROXY_PROFILE
base64 -i "$NOTARY_KEY" | set_secret NOTARY_API_KEY
printf '%s' "$KEY_ID" | set_secret NOTARY_KEY_ID
printf '%s' "$ISSUER" | set_secret NOTARY_ISSUER_ID
echo "Done. Run the Release workflow, or push a v* tag."

#!/bin/bash
# Builds a Developer ID signed, notarized Splyt.app and installs it in /Applications.
# System extensions only activate from /Applications on a Mac with SIP enabled.
#
# One-time setup:
#   1. Register App IDs in the Apple developer portal:
#        com.amplify2.splyt        Network Extensions, System Extension
#        com.amplify2.splyt.proxy  Network Extensions
#   2. Create a Developer ID profile for each, named exactly as below, and download
#      both to ~/Downloads (or set SPLYT_PROFILE_DIR).
#   3. Store notary credentials in the keychain:
#        xcrun notarytool store-credentials splyt --key <AuthKey.p8> --key-id <id> --issuer <id>
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM=A4XZSTY453
APP_ID=com.amplify2.splyt
EXT_ID=$APP_ID.proxy
APP_PROFILE="Splyt Developer ID"
EXT_PROFILE="Splyt Proxy Developer ID"
NOTARY_PROFILE=${SPLYT_NOTARY_PROFILE:-splyt}
PROFILE_DIR=${SPLYT_PROFILE_DIR:-$HOME/Downloads}
INSTALLED_PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
ENTITLEMENTS=(app-proxy-provider-systemextension packet-tunnel-provider-systemextension)
OUT=build/release
ARCHIVE=$OUT/Splyt.xcarchive

fail() {
    echo "error: $*" >&2
    exit 1
}

# True if the profile lists a certificate this Mac holds the private key for. A team
# can have several Developer ID certificates that share one name.
profile_has_local_certificate() {
    local plist=$1 index=0 encoded
    while encoded=$(plutil -extract "DeveloperCertificates.$index" raw "$plist" 2>/dev/null); do
        if base64 -D <<<"$encoded" | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F | grep -qxF "$LOCAL_CERTS"; then
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

# Installs the newest usable profile with this name and removes older installed
# copies, which would otherwise compete with it because they share the name.
install_profile() {
    local name=$1 bundle_id=$2 file plist uuid existing entitlement wrong_certificate=false
    plist=$(mktemp)
    while IFS= read -r file; do
        security cms -D -i "$file" >"$plist" 2>/dev/null || continue
        [[ $(plutil -extract Name raw "$plist") == "$name" ]] || continue

        if ! profile_has_local_certificate "$plist"; then
            wrong_certificate=true
            continue
        fi
        if [[ $(plutil -extract Entitlements.com\\.apple\\.application-identifier raw "$plist") != "$TEAM.$bundle_id" ]]; then
            rm -f "$plist"
            fail "profile \"$name\" is for the wrong App ID, expected $TEAM.$bundle_id"
        fi
        for entitlement in "${ENTITLEMENTS[@]}"; do
            if ! grep -q "$entitlement" "$plist"; then
                rm -f "$plist"
                fail "profile \"$name\" lacks $entitlement: enable Network Extensions on $bundle_id, then regenerate it"
            fi
        done
        uuid=$(plutil -extract UUID raw "$plist")
        mkdir -p "$INSTALLED_PROFILES"
        for existing in "$INSTALLED_PROFILES"/*.provisionprofile; do
            [[ -f $existing ]] || continue
            security cms -D -i "$existing" >"$plist" 2>/dev/null || continue
            if [[ $(plutil -extract Name raw "$plist") == "$name" ]]; then
                rm -f "$existing"
            fi
        done
        command cp -f "$file" "$INSTALLED_PROFILES/$uuid.provisionprofile"
        rm -f "$plist"
        echo "Installed profile: $name"
        return
    done < <(ls -t "$PROFILE_DIR"/*.provisionprofile 2>/dev/null)
    rm -f "$plist"
    if [[ $wrong_certificate == true ]]; then
        fail "profile \"$name\" does not include a certificate this Mac can sign with. Edit it in the developer portal, select one of these, and download it again:
$LOCAL_CERT_SUMMARY"
    fi
    fail "no profile named \"$name\" in $PROFILE_DIR"
}

# Checks what macOS will check at activation, when a mistake is far harder to diagnose.
verify_entitlements() {
    local bundle=$1 bundle_id=$2 plist entitlement
    plist=$(mktemp)
    codesign -d --entitlements :- "$bundle" 2>/dev/null >"$plist"
    for entitlement in "${ENTITLEMENTS[@]}"; do
        grep -q "$entitlement" "$plist" || fail "$bundle lacks $entitlement"
    done
    grep -q "$TEAM.$bundle_id" "$plist" || fail "$bundle lacks application identifier $TEAM.$bundle_id"
    if grep -q 'get-task-allow' "$plist"; then
        fail "$bundle has get-task-allow, which notarization rejects"
    fi
    rm -f "$plist"
}

echo "== Checking prerequisites"
LOCAL_CERTS=$(security find-identity -v -p codesigning \
    | awk -v team="($TEAM)" '/Developer ID Application/ && index($0, team) { print $2 }')
[[ -n $LOCAL_CERTS ]] || fail "Developer ID Application certificate for team $TEAM is not in the keychain"
LOCAL_CERT_SUMMARY=$(while IFS= read -r hash; do
    expiry=$(security find-certificate -a -Z -p -c "Developer ID Application" \
        | awk -v hash="$hash" '/^SHA-1 hash:/ { keep = ($3 == hash) } keep && !/^SHA/ { print }' \
        | openssl x509 -noout -enddate | cut -d= -f2)
    echo "  expires $expiry, SHA-1 $hash"
done <<<"$LOCAL_CERTS")
install_profile "$APP_PROFILE" "$APP_ID"
install_profile "$EXT_PROFILE" "$EXT_ID"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || fail "notary credentials \"$NOTARY_PROFILE\" not found, see the setup steps at the top of this script"

echo "== Building WireGuard"
# Built once; rerun scripts/build-wireguard.sh by hand after changing its pinned commit.
[[ -f build/wireguard/libwg-go.a ]] || scripts/build-wireguard.sh

echo "== Building"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodegen generate
# macOS only replaces an installed system extension when the build number changes.
xcodebuild -project Splyt.xcodeproj -scheme Splyt -configuration Release \
    -derivedDataPath "$OUT/derived" -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" archive

APP=$ARCHIVE/Products/Applications/Splyt.app
EXT=$APP/Contents/Library/SystemExtensions/$EXT_ID.systemextension

echo "== Verifying signature"
codesign --verify --deep --strict "$APP"
verify_entitlements "$APP" "$APP_ID"
verify_entitlements "$EXT" "$EXT_ID"

echo "== Notarizing (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/Splyt.zip"
RESULT=$OUT/notary.json
xcrun notarytool submit "$OUT/Splyt.zip" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json >"$RESULT"
if [[ $(plutil -extract status raw "$RESULT") != "Accepted" ]]; then
    xcrun notarytool log "$(plutil -extract id raw "$RESULT")" --keychain-profile "$NOTARY_PROFILE" >&2
    fail "notarization was rejected, details above"
fi
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"

echo "== Installing"
rm -rf /Applications/Splyt.app
ditto "$APP" /Applications/Splyt.app
echo "Installed /Applications/Splyt.app"

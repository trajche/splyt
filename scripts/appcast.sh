#!/bin/bash
# Writes the Sparkle appcast for one release, signing the archive with the
# update key. The Release workflow attaches it to the GitHub release, and apps
# read it from https://github.com/trajche/splyt/releases/latest/download/appcast.xml
#
#   scripts/appcast.sh <Splyt.app> <Splyt-x.y.z.zip> <download url> <out.xml>
#
# SPARKLE_ED_PRIVATE_KEY holds the Ed25519 private key as PEM (see
# scripts/sparkle-key.sh). Needs OpenSSL 3, which can sign raw Ed25519.
set -euo pipefail

APP=$1
ZIP=$2
URL=$3
OUT=$4
: "${SPARKLE_ED_PRIVATE_KEY:?set SPARKLE_ED_PRIVATE_KEY}"

OPENSSL=$(command -v /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl | head -1)
"$OPENSSL" version | grep -q '^OpenSSL 3' || { echo "error: OpenSSL 3 is required" >&2; exit 1; }

info() {
    plutil -extract "$1" raw "$APP/Contents/Info.plist"
}
VERSION=$(info CFBundleShortVersionString)
BUILD=$(info CFBundleVersion)
MINIMUM=$(info LSMinimumSystemVersion)
PUBLIC_KEY=$(info SUPublicEDKey)

umask 077
KEY=$(mktemp)
trap 'rm -f "$KEY"' EXIT
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" >"$KEY"

# The app only accepts archives signed by the key it carries.
derived=$("$OPENSSL" pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)
[[ $derived == "$PUBLIC_KEY" ]] || { echo "error: SPARKLE_ED_PRIVATE_KEY does not match SUPublicEDKey in the app" >&2; exit 1; }

SIGNATURE=$("$OPENSSL" pkeyutl -sign -rawin -inkey "$KEY" -in "$ZIP" | base64)
LENGTH=$(stat -f %z "$ZIP")
DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

cat >"$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Splyt</title>
    <link>https://github.com/trajche/splyt/releases</link>
    <item>
      <title>Splyt $VERSION</title>
      <link>https://github.com/trajche/splyt/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/trajche/splyt/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <pubDate>$DATE</pubDate>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
echo "Wrote $OUT for $VERSION (build $BUILD)"

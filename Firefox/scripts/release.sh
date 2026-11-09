#!/usr/bin/env bash
# Cut a release: sign the current source, publish the .xpi as a GitHub release,
# and point updates.json at it so installed copies update themselves.
#
#   Firefox/scripts/release.sh           patch release
#   Firefox/scripts/release.sh minor     minor release
#   Firefox/scripts/release.sh keep      release the current version
#
# Needs Firefox/.env with WEB_EXT_API_KEY / WEB_EXT_API_SECRET and the gh CLI.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="trajche/splyt-firefox"
ADDON_ID="$(node -p "require('./extension/manifest.json').browser_specific_settings.gecko.id")"

# sign.sh can fail after the upload has landed: the connection drops, or the
# version goes to review. AMO then refuses that number forever, so finish that
# release instead of uploading it again.
VERSION="$(node -p "require('./extension/manifest.json').version")"
if node scripts/amo.mjs status "$VERSION" >/dev/null 2>&1 &&
   ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "Version $VERSION is already on addons.mozilla.org; finishing that release."
else
  ./sign.sh "${1:-patch}" || echo "Signing did not return a file; checking addons.mozilla.org."
  VERSION="$(node -p "require('./extension/manifest.json').version")"
fi

RELEASE_FILE="web-ext-artifacts/splyt-$VERSION.xpi"
XPI="$(ls -t web-ext-artifacts/*"$VERSION"*.xpi 2>/dev/null | head -1 || true)"
if [ -n "$XPI" ]; then
  [ "$XPI" = "$RELEASE_FILE" ] || cp -f "$XPI" "$RELEASE_FILE"
else
  node scripts/amo.mjs fetch "$VERSION" "$RELEASE_FILE"
fi

# AMO returns whatever was uploaded under this version, which may be an older
# build. Publishing that would ship stale code under a new number.
different=""
while IFS= read -r file; do
  entry="${file#extension/}"
  a="$(printf '%s' "$(unzip -p "$RELEASE_FILE" "$entry" 2>/dev/null | LC_ALL=C tr -d '\0')" | shasum -a 256)"
  b="$(printf '%s' "$(LC_ALL=C tr -d '\0' < "$file")" | shasum -a 256)"
  [ "$a" = "$b" ] || different="$different $entry"
done < <(find extension -type f ! -name '.*')
if [ -n "$different" ]; then
  echo "The signed build for $VERSION is not this code. It differs in:$different" >&2
  echo "Its number cannot be reused, so bump to the next version." >&2
  exit 1
fi

TAG="v$VERSION"
NOTES="$(awk -v v="## $VERSION" '$0 == v { on = 1; next } on && /^## / { exit } on' CHANGELOG.md)"
gh release create "$TAG" "$RELEASE_FILE" --repo "$REPO" --title "Splyt $VERSION" \
  --notes "$(printf '%s\n\nInstall: open the .xpi below in Firefox. Installed copies update themselves. Requires the Splyt Mac app.' "$NOTES")"

HASH="sha256:$(shasum -a 256 "$RELEASE_FILE" | cut -d' ' -f1)"
LINK="https://github.com/$REPO/releases/download/$TAG/splyt-$VERSION.xpi"
CLONE="$(mktemp -d)"
trap 'rm -rf "$CLONE"' EXIT
gh repo clone "$REPO" "$CLONE" -- --quiet
node -e '
const fs = require("fs");
const [file, id, version, link, hash] = process.argv.slice(1);
const data = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : { addons: {} };
const entry = (data.addons[id] ??= { updates: [] });
entry.updates = entry.updates.filter((u) => u.version !== version);
entry.updates.push({ version, update_link: link, update_hash: hash });
entry.updates.sort((a, b) => a.version.localeCompare(b.version, undefined, { numeric: true }));
fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
' "$CLONE/updates.json" "$ADDON_ID" "$VERSION" "$LINK" "$HASH"
git -C "$CLONE" add updates.json
git -C "$CLONE" commit -q -m "Release $VERSION"
git -C "$CLONE" push -q

echo "Released $TAG"
echo "  $LINK"

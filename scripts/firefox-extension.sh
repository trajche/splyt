#!/bin/zsh
# Packages the Firefox extension as build/splyt-firefox-<version>.xpi.
#
# Release Firefox only keeps signed extensions installed. To get a signed .xpi
# without listing it publicly, create API credentials once at
# https://addons.mozilla.org/developers/addon/api/key/ and run:
#
#   WEB_EXT_API_KEY=... WEB_EXT_API_SECRET=... scripts/firefox-extension.sh --sign
set -euo pipefail

root=${0:A:h:h}
source_dir="$root/Firefox/extension"
output="$root/build"
version=$(node -p "require('$source_dir/manifest.json').version")
mkdir -p "$output"

if [[ "${1:-}" == "--sign" ]]; then
  : "${WEB_EXT_API_KEY:?Set WEB_EXT_API_KEY}"
  : "${WEB_EXT_API_SECRET:?Set WEB_EXT_API_SECRET}"
  npx --yes web-ext@8 sign --source-dir "$source_dir" --artifacts-dir "$output" --channel unlisted
else
  xpi="$output/splyt-firefox-$version.xpi"
  rm -f "$xpi"
  (cd "$source_dir" && zip -qr "$xpi" . -x '.*')
  echo "$xpi"
fi

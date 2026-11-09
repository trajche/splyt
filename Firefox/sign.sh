#!/bin/sh
# Signs an unlisted build with addons.mozilla.org. It never appears in public
# search. Keys come from Firefox/.env (WEB_EXT_API_KEY / WEB_EXT_API_SECRET).
#
#   ./sign.sh          patch:  0.1.0 -> 0.1.1
#   ./sign.sh minor    minor:  0.1.0 -> 0.2.0
#   ./sign.sh major    major:  0.1.0 -> 1.0.0
#   ./sign.sh keep     sign the current version
set -e
cd "$(dirname "$0")"
[ -f .env ] && . ./.env
: "${WEB_EXT_API_KEY:?missing, set it in Firefox/.env}"
: "${WEB_EXT_API_SECRET:?missing, set it in Firefox/.env}"
export WEB_EXT_API_KEY WEB_EXT_API_SECRET

node -e '
const fs = require("fs");
const file = "extension/manifest.json";
const kind = process.argv[1] || "patch";
const m = JSON.parse(fs.readFileSync(file, "utf8"));
const v = m.version.split(".").map(Number);
if (kind === "major") m.version = [v[0] + 1, 0, 0].join(".");
else if (kind === "minor") m.version = [v[0], v[1] + 1, 0].join(".");
else if (kind === "patch") m.version = [v[0], v[1], v[2] + 1].join(".");
fs.writeFileSync(file, JSON.stringify(m, null, 2) + "\n");
console.log("version: " + m.version);
' "${1:-patch}"

npx --yes web-ext@8 lint --source-dir extension --self-hosted --warnings-as-errors
npx --yes web-ext@8 sign --source-dir extension --artifacts-dir web-ext-artifacts \
  --channel unlisted

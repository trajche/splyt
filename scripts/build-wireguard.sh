#!/bin/bash
# Fetches WireGuardKit at a pinned commit and builds its Go half, libwg-go.a, as a
# universal static library in build/wireguard. The extension links it from there.
#
# Needs Go (brew install go). WireGuardKit's Makefile copies the Go toolchain and
# patches its clock to count time asleep, so tunnel timers stay right after sleep.
set -euo pipefail

cd "$(dirname "$0")/.."

REPO=https://github.com/WireGuard/wireguard-apple.git
COMMIT=2fec12a6e1f6e3460b6ee483aa00ad29cddadab1 # tag 1.0.16-27
VENDOR=Vendor/wireguard-apple
OUT=$PWD/build/wireguard

command -v go >/dev/null || { echo "error: Go is required: brew install go" >&2; exit 1; }

if [[ ! -d $VENDOR/.git ]]; then
    mkdir -p Vendor
    git clone --quiet "$REPO" "$VENDOR"
fi
if [[ $(git -C "$VENDOR" rev-parse HEAD) != "$COMMIT" ]]; then
    git -C "$VENDOR" fetch --quiet origin
    git -C "$VENDOR" checkout --quiet "$COMMIT"
fi

# Fixes for current Xcode: the manifest's tools version predates the platform names
# it uses, and a header relies on types it does not include.
PATCH=$PWD/scripts/wireguard-apple.patch
if git -C "$VENDOR" apply --check "$PATCH" 2>/dev/null; then
    git -C "$VENDOR" apply "$PATCH"
elif ! git -C "$VENDOR" apply --check --reverse "$PATCH" 2>/dev/null; then
    echo "error: $PATCH no longer applies to $VENDOR" >&2
    exit 1
fi

make -C "$VENDOR/Sources/WireGuardKitGo" \
    ARCHS="arm64 x86_64" \
    CONFIGURATION_BUILD_DIR="$OUT" \
    CONFIGURATION_TEMP_DIR="$OUT/tmp" \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    DEPLOYMENT_TARGET_CLANG_FLAG_NAME=mmacosx-version-min \
    DEPLOYMENT_TARGET_CLANG_ENV_NAME=MACOSX_DEPLOYMENT_TARGET

lipo -info "$OUT/libwg-go.a"

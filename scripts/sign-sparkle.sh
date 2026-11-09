#!/bin/bash
# Xcode build phase: re-signs the helpers inside Sparkle.framework with the app's
# identity, hardened runtime and a timestamp, which notarization requires. They
# ship signed by the Sparkle project. Xcode signs the app itself afterwards.
set -euo pipefail

[[ ${CODE_SIGNING_ALLOWED:-YES} == YES && -n ${EXPANDED_CODE_SIGN_IDENTITY:-} ]] || exit 0
[[ $CONFIGURATION == Release ]] || exit 0

framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
[[ -d $framework ]] || { echo "error: $framework is missing" >&2; exit 1; }
sign() {
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime --timestamp "$@"
}
helpers="$framework/Versions/B"
sign "$helpers/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$helpers/XPCServices/Downloader.xpc"
sign "$helpers/Autoupdate"
sign "$helpers/Updater.app"
sign "$framework"

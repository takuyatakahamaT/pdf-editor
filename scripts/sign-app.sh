#!/bin/zsh
set -euo pipefail
# Sign from the innermost code out. Sparkle's sandbox entitlements must survive.
APP_BUNDLE="${1:?Usage: sign-app.sh '/path/PDF editor.app'}"
SIGN_IDENTITY="${PDF_EDITOR_CODESIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:--}}"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements)
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--timestamp --options runtime)
fi
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
for SERVICE in "$SPARKLE"/XPCServices/*.xpc(N); do
    /usr/bin/codesign "${SIGN_ARGS[@]}" "$SERVICE"
done
/usr/bin/codesign "${SIGN_ARGS[@]}" "$SPARKLE/Autoupdate"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$SPARKLE/Updater.app"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
for HELPER in "$APP_BUNDLE"/Contents/Helpers/*(N); do
    /usr/bin/codesign "${SIGN_ARGS[@]}" "$HELPER"
done
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"

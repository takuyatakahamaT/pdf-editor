#!/bin/zsh
set -euo pipefail

APP_DIR="${0:A:h:h}"
APP_BUNDLE="$APP_DIR/dist/PDF editor.app"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    echo "DEVELOPER_ID_APPLICATION にDeveloper ID Applicationの署名IDを設定してください。" >&2
    exit 1
fi
if [[ -z "${APPLE_NOTARY_PROFILE:-}" ]]; then
    echo "APPLE_NOTARY_PROFILE にnotarytoolのKeychainプロファイル名を設定してください。" >&2
    exit 1
fi

"$APP_DIR/scripts/update-third-party-notices.sh"
"$APP_DIR/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Resources/Info.plist")"
ARCH="$(/usr/bin/uname -m)"
case "$ARCH" in
    arm64) ARCH_LABEL="arm64" ;;
    x86_64) ARCH_LABEL="x86_64" ;;
    *) echo "未対応のビルドアーキテクチャです: $ARCH" >&2; exit 1 ;;
esac

ARCHIVE_DIR="$APP_DIR/.build/release-archives"
UPLOAD_ZIP="$ARCHIVE_DIR/PDF-editor-$VERSION-$ARCH_LABEL-notary.zip"
FINAL_ZIP="$APP_DIR/dist/PDF-editor-$VERSION-macos-$ARCH_LABEL.zip"
/bin/mkdir -p "$ARCHIVE_DIR" "$APP_DIR/dist"
/bin/rm -f "$UPLOAD_ZIP" "$FINAL_ZIP"

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$UPLOAD_ZIP"
/usr/bin/xcrun notarytool submit "$UPLOAD_ZIP" \
    --keychain-profile "$APPLE_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$APP_BUNDLE"
/usr/bin/xcrun stapler validate "$APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP"
/usr/bin/shasum -a 256 "$FINAL_ZIP" > "$FINAL_ZIP.sha256"
/bin/cat "$FINAL_ZIP.sha256"
echo "配布ZIPを作成しました: $FINAL_ZIP"

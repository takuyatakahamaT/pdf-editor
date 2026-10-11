#!/bin/zsh
set -euo pipefail

APP_DIR="${0:A:h:h}"
APP_BUNDLE="$APP_DIR/dist/PDF editor.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
PDFCPU_VERSION="v0.16.1"
GO_COMMAND="$(command -v go || true)"

if [[ -z "$GO_COMMAND" ]]; then
    echo "Go 1.26以降が必要です（pdfcpu をアプリへ同梱するため）。" >&2
    exit 1
fi

/usr/bin/swift build -c release --package-path "$APP_DIR"
/bin/mkdir -p "$APP_DIR/.build/tools" "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Helpers" "$CONTENTS_DIR/Resources/ThirdParty"
GOBIN="$APP_DIR/.build/tools" "$GO_COMMAND" install "github.com/pdfcpu/pdfcpu/cmd/pdfcpu@$PDFCPU_VERSION"
/usr/bin/install -m 755 \
    "$APP_DIR/.build/release/PDFTextEditor" \
    "$CONTENTS_DIR/MacOS/PDFTextEditor"
/usr/bin/install -m 755 \
    "$APP_DIR/.build/tools/pdfcpu" \
    "$CONTENTS_DIR/Helpers/pdfcpu"
/bin/cp "$APP_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$APP_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/bin/rm -f "$CONTENTS_DIR/Resources/ThirdParty/pdfcpu-LICENSE.txt"
/usr/bin/install -m 644 \
    "$APP_DIR/Resources/ThirdParty/pdfcpu-LICENSE.txt" \
    "$CONTENTS_DIR/Resources/ThirdParty/pdfcpu-LICENSE.txt"

# SwiftPM signs the standalone executable before it is placed in the app
# bundle. Sign the completed bundle again so Finder/Gatekeeper can verify the
# final Info.plist and resources when it is launched by double-clicking.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"

echo "$APP_BUNDLE"

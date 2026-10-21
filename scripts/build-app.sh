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
(
    cd "$APP_DIR/Tools/pdf-compress"
    "$GO_COMMAND" build -trimpath -o "$APP_DIR/.build/tools/pdf-compress" .
)
/usr/bin/install -m 755 \
    "$APP_DIR/.build/release/PDFTextEditor" \
    "$CONTENTS_DIR/MacOS/PDFTextEditor"
/usr/bin/install -m 755 \
    "$APP_DIR/.build/tools/pdfcpu" \
    "$CONTENTS_DIR/Helpers/pdfcpu"
/usr/bin/install -m 755 \
    "$APP_DIR/.build/tools/pdf-compress" \
    "$CONTENTS_DIR/Helpers/pdf-compress"
/bin/cp "$APP_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$APP_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
RESOURCE_BUNDLE="$APP_DIR/.build/release/PDFTextEditor_PDFTextEditor.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "SwiftPMのフォントリソースが見つかりません: $RESOURCE_BUNDLE" >&2
    exit 1
fi
/bin/rm -rf "$CONTENTS_DIR/Resources/PDFTextEditor_PDFTextEditor.bundle"
/bin/cp -R "$RESOURCE_BUNDLE" "$CONTENTS_DIR/Resources/PDFTextEditor_PDFTextEditor.bundle"
/bin/rm -f "$CONTENTS_DIR/Resources/ThirdParty/pdfcpu-LICENSE.txt"
/usr/bin/install -m 644 \
    "$APP_DIR/Resources/ThirdParty/pdfcpu-LICENSE.txt" \
    "$CONTENTS_DIR/Resources/ThirdParty/pdfcpu-LICENSE.txt"
/usr/bin/install -m 644 \
    "$APP_DIR/Resources/ThirdParty/NotoSansJP-OFL.txt" \
    "$CONTENTS_DIR/Resources/ThirdParty/NotoSansJP-OFL.txt"

# SwiftPM signs the standalone executable before it is placed in the app
# bundle. Sign the completed bundle again so Finder/Gatekeeper can verify the
# final Info.plist and resources when it is launched by double-clicking.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"

echo "$APP_BUNDLE"

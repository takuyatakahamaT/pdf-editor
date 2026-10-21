#!/bin/zsh
set -euo pipefail

APP_DIR="${0:A:h:h}"
APP_BUNDLE="$APP_DIR/dist/PDF editor.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
GO_COMMAND="$(command -v go || true)"

if [[ -z "$GO_COMMAND" ]]; then
    echo "Go 1.26以降が必要です（pdfcpu をアプリへ同梱するため）。" >&2
    exit 1
fi

PDFCPU_VERSION="$(cd "$APP_DIR/Tools/pdf-compress" && "$GO_COMMAND" list -m -f '{{.Version}}' github.com/pdfcpu/pdfcpu)"
if [[ -z "$PDFCPU_VERSION" ]]; then
    echo "Tools/pdf-compress/go.mod からpdfcpuのバージョンを取得できません。" >&2
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
    "$APP_DIR/Resources/ThirdParty/THIRD-PARTY-NOTICES.txt" \
    "$CONTENTS_DIR/Resources/ThirdParty/THIRD-PARTY-NOTICES.txt"
/usr/bin/install -m 644 \
    "$APP_DIR/Resources/ThirdParty/NotoSansJP-OFL.txt" \
    "$CONTENTS_DIR/Resources/ThirdParty/NotoSansJP-OFL.txt"

# Developer ID identity is supplied only in the release environment. Local
# development builds keep an ad-hoc signature.
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    for executable in \
        "$CONTENTS_DIR/MacOS/PDFTextEditor" \
        "$CONTENTS_DIR/Helpers/pdfcpu" \
        "$CONTENTS_DIR/Helpers/pdf-compress"; do
        /usr/bin/codesign --force --options runtime --timestamp \
            --sign "$DEVELOPER_ID_APPLICATION" "$executable"
    done
    /usr/bin/codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APPLICATION" "$APP_BUNDLE"
else
    for executable in \
        "$CONTENTS_DIR/MacOS/PDFTextEditor" \
        "$CONTENTS_DIR/Helpers/pdfcpu" \
        "$CONTENTS_DIR/Helpers/pdf-compress"; do
        /usr/bin/codesign --force --sign - --timestamp=none "$executable"
    done
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "$APP_BUNDLE"

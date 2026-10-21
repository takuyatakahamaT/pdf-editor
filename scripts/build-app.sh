#!/bin/zsh
set -euo pipefail

APP_DIR="${0:A:h:h}"
APP_BUNDLE="${PDF_EDITOR_APP_BUNDLE:-$APP_DIR/dist/PDF editor.app}"
if /usr/bin/pgrep -f "^$APP_BUNDLE/Contents/MacOS/PDFTextEditor([[:space:]]|$)" >/dev/null; then
    echo "実行中のアプリは上書きできません。PDF_EDITOR_APP_BUNDLE で別の出力先を指定してください。" >&2
    exit 1
fi
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
SPARKLE_DIR="$APP_DIR/.build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework がありません。swift package resolve を実行してください。" >&2
    exit 1
fi
/bin/mkdir -p "$APP_DIR/.build/tools" "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Helpers" "$CONTENTS_DIR/Resources/ThirdParty" "$CONTENTS_DIR/Frameworks"
GOBIN="$APP_DIR/.build/tools" "$GO_COMMAND" install "github.com/pdfcpu/pdfcpu/cmd/pdfcpu@$PDFCPU_VERSION"
(
    cd "$APP_DIR/Tools/pdf-compress"
    "$GO_COMMAND" build -trimpath -o "$APP_DIR/.build/tools/pdf-compress" .
)
(
    cd "$APP_DIR/Tools/pdf-link-remap"
    "$GO_COMMAND" build -trimpath -o "$APP_DIR/.build/tools/pdf-link-remap" .
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
/usr/bin/install -m 755 \
    "$APP_DIR/.build/tools/pdf-link-remap" \
    "$CONTENTS_DIR/Helpers/pdf-link-remap"
/bin/cp "$APP_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -n "${PDF_EDITOR_BUILD_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PDF_EDITOR_BUILD_VERSION" "$CONTENTS_DIR/Info.plist"
fi
if [[ -n "${PDF_EDITOR_MARKETING_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PDF_EDITOR_MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
fi
/bin/rm -rf "$CONTENTS_DIR/Frameworks/Sparkle.framework"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
/usr/bin/install -m 644 "$SPARKLE_DIR/LICENSE" "$CONTENTS_DIR/Resources/ThirdParty/Sparkle-LICENSE.txt"
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

# Re-sign the complete app bundle, including Sparkle helpers, after packaging.
"$APP_DIR/scripts/sign-app.sh" "$APP_BUNDLE"

echo "$APP_BUNDLE"

#!/bin/zsh
set -euo pipefail

APP_DIR="${0:A:h:h}"
APP_BUNDLE="${PDF_EDITOR_APP_BUNDLE:-$APP_DIR/dist/PDF editor.app}"
PDFIUM_VERSION="chromium/8125"
PDFIUM_ARCHIVE_SHA256="0cf06803b9a4acc489fc967a1b05990622ca1cf41fa027ff9cc89eeab9b19279"
PDFIUM_ARCHIVE_URL="https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/8125/pdfium-mac-univ.tgz"
PDFIUM_ARCHIVE="${PDFIUM_ARCHIVE:-$APP_DIR/.build/downloads/pdfium-chromium-8125-mac-univ.tgz}"
if /usr/bin/pgrep -f "^$APP_BUNDLE/Contents/MacOS/PDFTextEditor([[:space:]]|$)" >/dev/null; then
    echo "実行中のアプリは上書きできません。PDF_EDITOR_APP_BUNDLE で別の出力先を指定してください。" >&2
    exit 1
fi
CONTENTS_DIR="$APP_BUNDLE/Contents"
GO_COMMAND="$(command -v go || true)"

/bin/mkdir -p "${PDFIUM_ARCHIVE:h}"
if [[ ! -f "$PDFIUM_ARCHIVE" ]]; then
    PDFIUM_DOWNLOAD="$PDFIUM_ARCHIVE.download"
    /usr/bin/curl --fail --location --retry 3 --output "$PDFIUM_DOWNLOAD" "$PDFIUM_ARCHIVE_URL"
    ACTUAL_PDFIUM_DOWNLOAD_SHA="$(/usr/bin/shasum -a 256 "$PDFIUM_DOWNLOAD" | /usr/bin/awk '{print $1}')"
    if [[ "$ACTUAL_PDFIUM_DOWNLOAD_SHA" != "$PDFIUM_ARCHIVE_SHA256" ]]; then
        /bin/rm -f "$PDFIUM_DOWNLOAD"
        echo "PDFium archiveのSHA256が一致しません。" >&2
        exit 1
    fi
    /bin/mv "$PDFIUM_DOWNLOAD" "$PDFIUM_ARCHIVE"
fi
ACTUAL_PDFIUM_SHA="$(/usr/bin/shasum -a 256 "$PDFIUM_ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL_PDFIUM_SHA" != "$PDFIUM_ARCHIVE_SHA256" ]]; then
    echo "PDFium archiveのSHA256が一致しません: $PDFIUM_ARCHIVE" >&2
    exit 1
fi
PDFIUM_EXTRACT_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pdf-editor-pdfium.XXXXXX")"
trap '/bin/rm -rf "$PDFIUM_EXTRACT_DIR"' EXIT
/usr/bin/tar -xzf "$PDFIUM_ARCHIVE" -C "$PDFIUM_EXTRACT_DIR"
if [[ ! -f "$PDFIUM_EXTRACT_DIR/lib/libpdfium.dylib" || ! -f "$PDFIUM_EXTRACT_DIR/LICENSE" \
      || ! -d "$PDFIUM_EXTRACT_DIR/licenses" ]]; then
    echo "固定PDFium archiveの構成が不正です。" >&2
    exit 1
fi
/usr/bin/lipo "$PDFIUM_EXTRACT_DIR/lib/libpdfium.dylib" -verify_arch arm64 x86_64

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
/usr/bin/install -m 755 "$PDFIUM_EXTRACT_DIR/lib/libpdfium.dylib" "$CONTENTS_DIR/Frameworks/libpdfium.dylib"
/usr/bin/install_name_tool -id "@rpath/libpdfium.dylib" "$CONTENTS_DIR/Frameworks/libpdfium.dylib"
/bin/rm -rf "$CONTENTS_DIR/Resources/ThirdParty/PDFium"
/bin/mkdir -p "$CONTENTS_DIR/Resources/ThirdParty/PDFium/licenses"
/usr/bin/install -m 644 "$PDFIUM_EXTRACT_DIR/LICENSE" "$CONTENTS_DIR/Resources/ThirdParty/PDFium/LICENSE"
/usr/bin/install -m 644 "$PDFIUM_EXTRACT_DIR/VERSION" "$CONTENTS_DIR/Resources/ThirdParty/PDFium/VERSION"
/usr/bin/install -m 644 "$PDFIUM_EXTRACT_DIR"/licenses/* "$CONTENTS_DIR/Resources/ThirdParty/PDFium/licenses/"
echo "$PDFIUM_VERSION" > "$CONTENTS_DIR/Resources/ThirdParty/PDFium/PINNED-VERSION.txt"
echo "$PDFIUM_ARCHIVE_SHA256  pdfium-mac-univ.tgz" > "$CONTENTS_DIR/Resources/ThirdParty/PDFium/SHA256SUMS"
if ! /usr/bin/cmp -s "$PDFIUM_EXTRACT_DIR/LICENSE" "$CONTENTS_DIR/Resources/ThirdParty/PDFium/LICENSE" \
   || ! /usr/bin/diff -qr "$PDFIUM_EXTRACT_DIR/licenses" "$CONTENTS_DIR/Resources/ThirdParty/PDFium/licenses" >/dev/null; then
    echo "PDFiumのlicense noticeを完全に収録できませんでした。" >&2
    exit 1
fi
/bin/cp "$APP_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
FONT_RESOURCE="$APP_DIR/Sources/PDFTextEditor/Resources/Fonts/NotoSansJP-Regular.otf"
FONT_RESOURCE_DEST="$CONTENTS_DIR/Resources/Fonts/NotoSansJP-Regular.otf"
/bin/rm -rf "$CONTENTS_DIR/PDFTextEditor_PDFTextEditor.bundle"
/bin/rm -rf "$CONTENTS_DIR/Resources/PDFTextEditor_PDFTextEditor.bundle"
if [[ ! -f "$FONT_RESOURCE" ]]; then
    echo "アプリ同梱フォントが見つかりません: $FONT_RESOURCE" >&2
    exit 1
fi
/bin/mkdir -p "${FONT_RESOURCE_DEST:h}"
/usr/bin/install -m 644 "$FONT_RESOURCE" "$FONT_RESOURCE_DEST"
if [[ ! -s "$FONT_RESOURCE_DEST" ]]; then
    echo "アプリ同梱フォントを配置できません: $FONT_RESOURCE_DEST" >&2
    exit 1
fi
/bin/rm -rf "$APP_BUNDLE/PDFTextEditor_PDFTextEditor.bundle"
/usr/bin/swift "$APP_DIR/scripts/verify-app-resources.swift" "$APP_BUNDLE"
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
/usr/bin/codesign --verify --strict --verbose=2 "$CONTENTS_DIR/Frameworks/libpdfium.dylib"
/usr/bin/lipo "$CONTENTS_DIR/Frameworks/libpdfium.dylib" -verify_arch arm64 x86_64
if [[ "$(/usr/bin/otool -D "$CONTENTS_DIR/Frameworks/libpdfium.dylib" | /usr/bin/tail -1)" != "@rpath/libpdfium.dylib" ]]; then
    echo "PDFium dylibのinstall nameが不正です。" >&2
    exit 1
fi

echo "$APP_BUNDLE"

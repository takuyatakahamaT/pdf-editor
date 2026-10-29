#!/bin/zsh
set -euo pipefail

# Resources/AppIcon.svg を正として、AppIcon.png（1024px）と AppIcon.icns を作り直す。
# 描画には Google Chrome のヘッドレスモードを使う（feDropShadow を含めて表示どおりに出すため）。
APP_DIR="${0:A:h:h}"
RESOURCES_DIR="$APP_DIR/Resources"
CHROME="${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WORK_DIR="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$WORK_DIR"' EXIT

if [[ ! -x "$CHROME" ]]; then
    echo "Google Chrome が見つかりません。CHROME_PATH で実行ファイルを指定してください。" >&2
    exit 1
fi

"$CHROME" --headless --disable-gpu --hide-scrollbars --no-first-run \
    --force-device-scale-factor=1 --default-background-color=00000000 \
    --window-size=1024,1024 --user-data-dir="$WORK_DIR/chrome-profile" \
    --screenshot="$WORK_DIR/AppIcon.png" "file://$RESOURCES_DIR/AppIcon.svg" >/dev/null 2>&1

RENDERED_SIZE="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$WORK_DIR/AppIcon.png" | /usr/bin/awk '/pixel/ {printf "%s ", $2}')"
if [[ "$RENDERED_SIZE" != "1024 1024 " ]]; then
    echo "AppIcon.svg の描画サイズが 1024x1024 ではありません: $RENDERED_SIZE" >&2
    exit 1
fi

ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
/bin/mkdir "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$WORK_DIR/AppIcon.png" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$((size * 2))" "$((size * 2))" "$WORK_DIR/AppIcon.png" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
/bin/cp "$WORK_DIR/AppIcon.png" "$RESOURCES_DIR/AppIcon.png"
echo "AppIcon.png と AppIcon.icns を更新しました。"

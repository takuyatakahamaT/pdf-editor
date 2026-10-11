#!/bin/zsh
set -euo pipefail

APP_DIR="${0:A:h}"
APP_BUNDLE="$APP_DIR/dist/PDF editor.app"

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/PDFTextEditor" ]]; then
    "$APP_DIR/scripts/build-app.sh"
fi

exec /usr/bin/open -n "$APP_BUNDLE" --args "$@"

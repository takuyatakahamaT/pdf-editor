#!/bin/bash
# Runs only on trusted main in the GitHub release environment. Never enable xtrace.
set -euo pipefail
SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_ROOT"
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || { echo 'main からだけ公開できます。' >&2; exit 1; }
[[ "${GITHUB_REPOSITORY:-}" == takuyatakahamaT/pdf-editor ]] || { echo '配布先リポジトリが一致しません。' >&2; exit 1; }
for SECRET_NAME in SPARKLE_PRIVATE_KEY; do
    [[ -n "${!SECRET_NAME:-}" ]] || { echo "release Environment の Secret $SECRET_NAME が必要です。公開を停止します。" >&2; exit 1; }
done
python3 - <<'PY'
import base64, plistlib
with open('Resources/Info.plist', 'rb') as source:
    key = plistlib.load(source)['SUPublicEDKey']
try:
    data = base64.b64decode(key, validate=True)
except ValueError:
    raise SystemExit('SUPublicEDKey が未設定です。署名付き更新を公開しません。')
if len(data) != 32 or not any(data):
    raise SystemExit('SUPublicEDKey は有効な Ed25519 公開鍵である必要があります。')
PY
[[ "$GITHUB_RUN_NUMBER" =~ ^[0-9]+$ ]] || exit 1
BUILD_VERSION="$((1000 + GITHUB_RUN_NUMBER))"
VERSION="0.6.${GITHUB_RUN_NUMBER}"
TAG="pdf-editor-${BUILD_VERSION}"
# Never move latest backwards when an older workflow run is retried.
EXISTING_TAGS="$(gh release list --repo "$GITHUB_REPOSITORY" --limit 1000 --json tagName --jq '.[].tagName')"
MAX_PUBLISHED="$(printf '%s\n' "$EXISTING_TAGS" | sed -nE 's/^pdf-editor-([0-9]+)$/\1/p' | sort -n | tail -1)"
[[ -z "$MAX_PUBLISHED" || "$BUILD_VERSION" -gt "$MAX_PUBLISHED" ]] || { echo '同じ版または新しい版が存在します。main の新しい workflow_dispatch で再実行してください。' >&2; exit 1; }
WORK_DIR="$(mktemp -d "${RUNNER_TEMP:?}/pdf-editor-release.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
export PDF_EDITOR_APP_BUNDLE="$WORK_DIR/PDF editor.app"
export PDF_EDITOR_BUILD_VERSION="$BUILD_VERSION"
export PDF_EDITOR_MARKETING_VERSION="$VERSION"
export PDF_EDITOR_CODESIGN_IDENTITY=-
scripts/build-app.sh
mkdir "$WORK_DIR/updates"
ARCHIVE="$WORK_DIR/updates/PDF-editor-${VERSION}-arm64.zip"
[[ "$(uname -m)" == arm64 ]] || { echo '公開 runner は arm64 が必要です。' >&2; exit 1; }
/usr/bin/ditto -c -k --keepParent "$PDF_EDITOR_APP_BUNDLE" "$ARCHIVE"
codesign --verify --strict --deep --verbose=2 "$PDF_EDITOR_APP_BUNDLE"
SPARKLE_TOOLS="$SCRIPT_ROOT/.build/artifacts/sparkle/Sparkle/bin"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_TOOLS/generate_appcast" --ed-key-file - --maximum-deltas 0 --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/" "$WORK_DIR/updates"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_TOOLS/sign_update" --ed-key-file - --verify "$WORK_DIR/updates/appcast.xml"
swift scripts/verify-release.swift "$PDF_EDITOR_APP_BUNDLE/Contents/Info.plist" "$WORK_DIR/updates/appcast.xml" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" | sed "s|$WORK_DIR/updates/||" > "$WORK_DIR/updates/SHA256SUMS"
printf 'PDF editor %s\n\nソース: %s\n\nApple Silicon / macOS 14以降。アプリはad-hoc署名、更新archiveとappcastはSparkle Ed25519署名です。アプリメニューの「アップデートを確認」から更新し、利用者が再起動を選ぶと適用されます。\n' "$VERSION" "$GITHUB_SHA" > "$WORK_DIR/release-notes.md"
gh release create "$TAG" "$ARCHIVE" "$WORK_DIR/updates/appcast.xml" "$WORK_DIR/updates/SHA256SUMS" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --draft --title "PDF editor $VERSION" --notes-file "$WORK_DIR/release-notes.md"
# The draft is only made visible after every payload and signed feed is uploaded.
gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false --latest
printf '公開済み: https://github.com/%s/releases/tag/%s\n' "$GITHUB_REPOSITORY" "$TAG"

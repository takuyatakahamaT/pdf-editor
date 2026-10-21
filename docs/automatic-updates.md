# PDF editor の署名付き自動更新

main にマージすると `Signed macOS release` が Apple Silicon 向けアプリをビルドし、受入テスト、Developer ID 署名、公証、Sparkle Ed25519 署名の確認後、GitHub Release を公開します。公開済みの ZIP と `appcast.xml` が揃うまで draft のままにします。公開済み版より小さい版を latest に戻しません。ビルド番号は `1000 + GITHUB_RUN_NUMBER` です。

アプリは起動後と1時間ごとに最新 Release の appcast を確認します。Sparkle の標準画面からユーザーがインストールと再起動を選びます。未確定の文字入力があると再起動を延期します。編集済みPDFがある場合は保存パネルで別名への書き出しが成功してから再起動し、保存したPDFを開き直します。キャンセルや書き出し失敗ではそのまま編集を続けられ、アプリメニューの「更新して再起動」から再試行できます。

ダウンロードの前後に appcast と ZIP の Ed25519 署名を Sparkle が確認します。`SUVerifyUpdateBeforeExtraction` と `SURequireSignedFeed` を有効にし、署名検証失敗の期限切れによるフォールバックも無効にしています。公開鍵がプレースホルダー、空、不正な場合は更新を初期化しません。PR CI は署名鍵なしでビルド、受入テスト、同梱物の ad hoc 署名検証まで行います。`scripts/check-update-security.py` では秘密鍵を含まないRFC 8032の公開ベクトルで、正常署名の受入、不正署名・改変・署名欠落の拒否、鍵未設定時の配布停止を毎回確認します。PRコードに配布用Secretは渡しません。

## 初回にオーナーが設定するもの

現時点の `SUPublicEDKey` はプレースホルダーです。**このままでは更新を検知・適用せず、リリースも停止します。** 秘密鍵を生成・参照する作業は、この実装には含めていません。

1. オーナーの信頼できる Mac で、Sparkle 公式の `generate_keys` を使用して鍵を用意してください。秘密鍵は Keychain と安全なバックアップに保管してください。エージェントやIssue・PRへ秘密鍵を貼らないでください。
2. **公開鍵だけ**を `Resources/Info.plist` の `SUPublicEDKey` に設定してPRを作成してください。SparkleとTauriの鍵形式は異なるため、NIHO docsの鍵をコピーしません。
3. GitHub の `release` Environment を作成し、配布対象を main に限定してください。以下のSecretを設定してください。

| Secret | 内容 |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | Sparkle `generate_keys` のエクスポート形式の秘密鍵（`generate_appcast --ed-key-file -` に標準入力で渡す） |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Developer ID Application証明書のp12をbase64化した値 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | p12のパスワード |
| `DEVELOPER_ID_CODESIGN_IDENTITY` | `Developer ID Application: ... (TEAMID)` の完全な署名ID |
| `APPLE_ID` | Apple公証に使用するApple ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | 公証用のアプリ用パスワード |

4. GitHub repository variable `PDF_EDITOR_RELEASES_ENABLED=true` を設定してください。これがない間は main へのpush後もRelease jobを開始しません。
5. main で `Signed macOS release` を実行し、ZIP・署名付き appcast・SHA256SUMS の公開を確認してください。秘密値不足では未署名版を公開しません。失敗したdraftは内容確認後に削除し、新しい workflow_dispatch で上位の版を作ってください。
6. 初回は、この公開鍵と Sparkle.framework を含むビルドを `/Applications/PDF editor.app` へ手動で導入してください。既存の旧アプリは自動更新コードを持たないため、この1回の導入が必要です。以降はアプリ自身が更新を案内します。

## ビルドと同梱物

`PDF_EDITOR_APP_BUNDLE='/tmp/PDF editor candidate.app' scripts/build-app.sh` で実行中のアプリと別の場所へ作れます。実行中の出力先への上書きは拒否します。`PDF_EDITOR_CODESIGN_IDENTITY` を省略したローカルビルドは ad hoc 署名です。配布workflowは Developer ID 署名・公証を必須にしています。

SwiftPMで固定した Sparkle 2.10.0 の universal framework を `Contents/Frameworks` へ symlink を保って同梱し、Downloader / Installer XPC、Autoupdate、Updater.app、framework、アプリ本体の順に署名します。Sparkleのsandbox entitlementsは保持します。このアプリ自体はsandbox化していません。現在のReleaseはApple Silicon版で、生成appcastにも対応アーキテクチャを反映します。

## 参照

- [採用版 Sparkle 2.10.0 の公式Release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)（`Package.swift`でexact固定、SwiftPMチェックサム検証）
- [Sparkle公式セットアップ・署名](https://sparkle-project.org/documentation/)
- [Sparkle公式更新動作・セキュリティ設定](https://sparkle-project.org/documentation/customization/)
- [NIHO docs updaterの公開鍵未設定時の停止と再起動UX](https://github.com/niho-coliving/niho-docs/blob/main/apps/docs/src-tauri/src/updater.rs)

署名鍵と公開環境が揃うまで、実際のRelease取得・インストール・再起動の一連の受入は未完了です。鍵を持つオーナーの環境で、旧版から上位版への更新、署名不正の拒否、PDF書き出しキャンセル時の継続、書き出し後のPDF再表示を確認してください。

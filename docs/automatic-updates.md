# PDF editor の署名付き・手動承認アップデート

main にマージすると `Sparkle署名付き更新` workflow が Apple Silicon 向けアプリをビルドし、受入テストと Sparkle Ed25519 署名を確認して GitHub Release を公開します。アプリ内の更新機能は署名付きappcastを自動確認しますが、インストールと再起動は利用者が画面で選んだときだけ行います。ダウンロード用ZIPはSparkleがアプリ内で検証・展開する内部形式で、利用者が手動で置き換える必要はありません。公開済みのZIPと `appcast.xml` が揃うまでdraftのままにし、公開済み版より小さい版をlatestに戻しません。ビルド番号は `1000 + GITHUB_RUN_NUMBER` です。

アプリは起動後と1時間ごとに更新を確認し、「PDF editor」メニューからも確認できます。自動確認で新しい版が見つかった場合は、Sparkleの署名検証を通した後にアプリ画面上部へ「更新して再起動」ボタンを表示します。ボタンからSparkleの更新確認へ進み、利用者が更新を確定した後に適用します。未確定の文字入力がある場合は再起動を延期します。編集済みPDFは保存パネルで別ファイルへの書き出しが成功してから更新を適用し、保存したPDFを再起動後に開き直します。キャンセルや書き出し失敗では編集を続けられます。保存・再起動が保留中なら、アプリメニューの「更新して再起動」から再試行できます。

SparkleがappcastとアプリのZIPのEd25519署名を検証します。`SUVerifyUpdateBeforeExtraction` と `SURequireSignedFeed` を有効にし、署名検証失敗時の期限切れフォールバックも無効にしています。公開鍵がプレースホルダー、空、不正な場合は更新機能を初期化しません。PR CIは配布用秘密鍵なしでビルド、受入テスト、同梱物のad hoc署名確認を行います。`scripts/check-update-security.py` はRFC 8032公開ベクトルで正常署名、不正署名、改変、署名欠落、秘密鍵未設定時の配布停止を検証します。PRコードには配布用Secretを渡しません。

## 配布設定

`SUPublicEDKey` は既にアプリへ組み込まれています。対応するSparkle秘密鍵はGitHubの `release` Environment に `SPARKLE_PRIVATE_KEY` として登録済みで、Environmentの配布対象は `main` に限定しています。**秘密鍵を再生成すると公開鍵が変わり、既存アプリへ更新を届けられなくなるため、再生成しないでください。** Release workflowに必要なSecretはこの1つだけです。Apple Developer ID証明書と公証情報は不要です。

GitHub repository variable `PDF_EDITOR_RELEASES_ENABLED=true` があるとmainへのpushでRelease jobが動きます。公開前にPR CI、公開鍵と秘密鍵の一致、Sparkleの署名検証を通すこと。失敗したdraftは内容確認後に削除し、新しい `workflow_dispatch` でより大きいビルド番号を発行します。Releaseを有効にしていない間は、mainへのpushだけでは配布されません。

この方法ではアプリ本体はad hoc署名となり、Apple Developer ID署名・公証は付きません。すでに同じSparkle公開鍵と更新機能を持つアプリへの更新はSparkle署名で検証できます。一方、GitHubから新しくダウンロードしたアプリの初回起動にはGatekeeperの警告や制限が出る場合があります。新規購入者へ配布する際はDeveloper ID署名と公証が別途必要です。

## ビルドと同梱物

`PDF_EDITOR_APP_BUNDLE='/tmp/PDF editor candidate.app' scripts/build-app.sh` で実行中のアプリと別の場所へ候補を作成できます。実行中の出力先への上書きは拒否します。ローカルビルドと更新用Releaseはad hoc署名です。SwiftPMで固定したSparkle 2.10.0 universal frameworkを `Contents/Frameworks` へ同梱し、Downloader / Installer XPC、Autoupdate、Updater.app、framework、アプリ本体の順に署名します。Sparkleのsandbox entitlementsは保持します。このアプリ自体はsandbox化していません。現在のReleaseはApple Silicon版で、生成appcastにも対応アーキテクチャを反映します。

## 参照

- [採用版 Sparkle 2.10.0 の公式Release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)（`Package.swift`でexact固定、SwiftPMチェックサム検証）
- [Sparkle公式セットアップ・署名](https://sparkle-project.org/documentation/)
- [Sparkle公式更新動作・セキュリティ設定](https://sparkle-project.org/documentation/customization/)
- [NIHO docs updaterの公開鍵未設定時の停止と再起動UX](https://github.com/niho-coliving/niho-docs/blob/main/apps/docs/src-tauri/src/updater.rs)

Releaseを有効化した後、同じ公開鍵を含む旧版からの更新、署名不正の拒否、PDF書き出しキャンセル時の継続、書き出し後のPDF再表示を実アプリで受け入れ確認してください。新規インストールのGatekeeper通過はDeveloper ID署名と公証を設定してから確認します。

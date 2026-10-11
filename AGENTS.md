# PDF editor agent instructions

- オーナーへの報告とコミットメッセージは日本語で書く。
- 個人用のPDF・画像・CSVなど実データは `tmp/` に置き、Gitへ追加しない。テストの固定データはテスト内で生成する。
- ソースの正はこのリポジトリ。`~/Desktop/PDF editor.app` はビルド済みアプリであり、ソースではない。
- 変更後は `swift build -c release`、`swift test`、必要に応じて `scripts/verify-edit.py` を実行する。ページサイズ変更の結合テストは、同梱した `pdfcpu` のパスを `PDFCPU_PATH` に指定して実行する。
- デスクトップのアプリを差し替える前にバックアップとコード署名の検証を行う。作業中の選択や編集を保持するため、実行中のアプリは終了させない。

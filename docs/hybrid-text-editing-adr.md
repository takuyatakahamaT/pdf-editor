# ADR: 既存PDFテキスト編集を対応判定付きの混合方式へ移行する

- 対象: Issue #19
- 記録日・公式資料確認日: 2026-10-21
- 状態: 段階移行の設計を採用。SDK選定・導入は後続の実証で決定する。

## 決定

元のページ内容を変更できると証明できた選択範囲だけを内部編集の候補にし、それ以外は安全性を確認したoverlayへ送る。overlayでも文字欠落や他要素の消去を防げなければ編集を拒否し、理由を表示する。SDKの導入だけで対応範囲が広がったと扱わない。

1,000円買切りMVPではApryse・Nutrient・MuPDFの商用ライセンスを見積取得まで保留する。PDFiumをSDK使用料のない実証候補として残すが、ビルド・配布・脆弱性更新・対応範囲の実証を含む保守費を評価してから決める。今回の成果は設計と生成fixtureの境界テストであり、ランタイムの編集方式や既存rendererは変更しない。

## 現状と解決すべき欠落

`PDFGlyphIndex` / `PDFContentScanner` はcontent streamを走査し、`ScannedGlyph`を視覚的な`ScannedRun`にまとめ、`TextTarget` / `TextRunLayout`を作る。文字・送り幅・フォントリソース名はあるが、元stream、show operatorの位置・オペランド範囲、Form XObjectの参照経路、PDFiumの`FPDF_PAGEOBJECT`との対応は保持しない。見た目が連続したrunが、編集SDKの1個のtext objectに一致する保証はない。

`PDFExportEngine.export`は元PDFをPDFKitで描き直し、`PDFTextRenderer`がcoverと置換文字の輪郭を描く。元の文字をcontent streamから削除する処理ではなく、元の文字が抽出・検索できることがある。`fontIsExact`も元フォントの再現に関する値であり、元オブジェクトを特定できたことや内部編集の可否を表す値には使えない。

ToUnicodeを持たない単純フォントにはASCIIの推定値を補うが、Type0では不明文字が空文字になる。現在は一部の不明文字でも選択用のboxを作れるため、「表示上選べた」ことを安全性の証明にしない。`lineLayout == nil`や空の文字列は、後続の拒否・警告判定で扱う必要がある。

匿名のローカルPDF 15件を先頭3ページまで調べたところ、全件をPDFKitで開けた。走査した18ページのうち16ページで文字グリフを得て、合計5,695 glyph / 1,120 runを検出した。Unicode未解決は1文書の8 glyphで、全8件に視覚的targetを作れた。置換overlayの書き出し・再open・画像化はtargetのある14件で成功し、1件はscanner targetがなかった。この集計は現行経路の動作確認であり、内部編集の可否、原文除去、全PDF対応を示さない。元のPDF・画像・抽出内容はリポジトリに保存しない。

## 方式の比較と採否

以下のサイズは未計測。SDKのダウンロード容量と最終`.app`の増分を混同せず、採用候補の固定version・有効機能・各architectureでrelease buildを作って測る。外部SDKはmacOS 14以降の対象architecture、SwiftとのC/C++ bridge、メモリ所有権、sandbox、署名・notarization、更新手順を実証する。

| 方式 | API能力と限界 | macOS配布・build・サイズ | 価格・義務・判断 |
| --- | --- | --- | --- |
| 現行PDFKit + overlay | 既存の選択・代替フォント・行の再描画を利用可能。原文の除去や構造保持は保証しない | OS frameworkを利用し外部エンジン追加なし。既存の同梱フォント容量は別。サイズ増分の基準にする | 追加SDK料金なし。現行経路を継続し、将来の安全判定と限界表示を追加する |
| PDFium | `FPDFPage_GetObject`等でpage objectを取得し、`FPDFText_SetText`でtext objectの既存文字列を置換、`FPDFPage_GenerateContent`で反映できる。任意のglyph spanや複数のTj/TJを視覚上の文字列から安全に特定・再配置する保証ではない。[編集API][pdfium-edit] | Chromium系depot_tools/GN/Ninja/Clangを使用。JS/XFA等の構成を絞り、対象architectureごとの成果物・bridge・依存物を自前管理する。公式build説明はSwift向け完成品の配布契約ではない。[build][pdfium-build] | [GitHubのライセンス表示][pdfium-github]はBSD-3-Clause。[LICENSE][pdfium-license]は冒頭のBSD式通知に続いてApache-2.0本文も含む。この2つだけでPDFium全体を単純なdual licenseと断定しない。採用する固定revision、配布binaryとthird_partyの各著作権・ライセンス・NOTICEを精査し、必要な通知・免責・変更表示を配布物へ反映する。SDK使用料以外の保守・組み込み負担があり、今回は導入保留 |
| Apryse | `ContentReplacer`で領域内の文字・テンプレート文字列を置換できる。領域選択が隣接文字を含まないこと、任意PDFの日本語・subset・分割operatorの対応は実証が必要。[置換ガイド][apryse-edit] | macOS向けnative SDKがある。配布ライブラリとbridge、対象architecture・OS・選択moduleの確認、releaseサイズ計測が必要。[macOS][apryse-mac] | 公式[料金案内][apryse-price]はentry-level packages from $1,500と要件に応じたカスタム価格を提示する。これを本件の年額や確定額とは扱わない。既存文字編集・macOS再配布が最低価格に含まれるとは限らない。商用契約で配布権・license key・module・更新条件を確認する。今回は見積取得まで保留 |
| Nutrient | [Content Editor][nutrient-content]はPDFのtext layerを直接編集し、段落・text blockの編集を案内する。製品の選択単位と本アプリのglyph単位選択との一致、fragmented operator、日本語・subsetの可否を検証する必要がある | [macOS SDK][nutrient-mac]はmacOSでの表示・編集を案内する。Content Editorの対応形態はMac Catalyst等であり、既存のnative AppKitアプリへ組み込む手段、framework、署名・公証、対象architecture、releaseサイズを試用時に確認する | [料金案内][nutrient-price]は年額subscriptionとSales見積を案内し、[試用案内][nutrient-try]は30日evaluationを提示する。生産配布には商用契約が必要。必要機能・macOS配布条件と価格が未確定のため見積取得まで保留 |
| MuPDF | C APIにPDF stream更新・保存の基盤があるが、任意の視覚上の選択を元の文字演算子に戻す仕組みは別途必要。低レベルの更新APIをWord型編集の保証と扱わない。[stream API][mupdf-stream] | macOSはGNU makeを使うbuild対象。標準macOS viewerはなく、アプリUI・bridge・同梱依存・署名を自前管理する。対象構成のサイズは未計測。[build][mupdf-build] | [公式ライセンス案内][artifex-license]はAGPLv3または個別商用契約。AGPL採用なら対応するソース提供・ライセンス通知等、アプリを含む適合性の確認が必要。非公開アプリへの組み込みを無償と仮定しない。商用OEM等にはper-copy課金・四半期最低料金のモデルがあるが、このアプリへの確定見積りではない。今回は購入しない |

商用SDKの価格は公開案内であり、確定見積りではない。1本の税・販売手数料・サポートを引いた限界利益を`m`円、年間固定ライセンス費を`L`円、販売数を`n`、1本のSDK従量費を`r`円とすれば、SDK費だけでも`n × (m − r) ≥ L`が必要になる。現時点では為替、契約範囲、最低料金、販売数が未確定で採算を証明できない。無償エンジンも実装・更新工数を含めて比較する。

## 対応判定の契約

判定結果は、後続実装で次の3種類にする。下記は設計上の名称で、現行コードに追加済みの型ではない。

- `internalCandidate`: 元の編集範囲と書き換え方法を証明できる。まだ成功を意味せず、保存・再読込・比較が通った場合だけ確定する。
- `overlay`: 内部編集の条件を満たさないが、cover領域・必要全文字の描画・周辺非干渉を証明できる。表示には原文が残り得ることを伝える。
- `unsupported`: どちらも安全性を証明できない。理由を表示して確定・書き出しを拒否する。

| 観点 | 内部編集の候補条件 | 条件外の扱い・理由コード案 |
| --- | --- | --- |
| 元stream / operator / object | 文書revision、page、stream参照・Form経路、operator位置、元bytesと選択範囲、SDK objectの対応を記録し、一意に照合できる | 対応なし・曖昧・shared XObjectの副作用は`sourceIdentityUnknown`。座標や抽出文字列の一致だけでは変更しない |
| Tj / TJのgrouping | 初期対象は完全に特定した単一text object全体。部分変更を行うにはprefix/suffix、TJ調整値、文字・単語間隔、次のtext positionまで保存・再現できることを別途実証する | 複数show operationをまとめたrun、範囲がobjectをまたぐ場合は`fragmentedShowOperations`。安全なoverlayを検討する |
| ToUnicode | 元code→Unicodeの対応と逆変換が一意。code幅・Encoding CMapも解決済み | 未定義、ASCII推定だけ、重複逆引き、多文字mapping/合字・結合文字を個々の文字と誤認する場合は`unicodeMappingUnknown` / `unicodeMappingAmbiguous`。不明な周辺文字を再描画するoverlayは拒否 |
| CIDToGIDMap | Encoding→CID→GIDを追跡できる。Identity-Hだけでは不十分で、CIDFontType2のmapと実際のfont glyph範囲を検証する | 非Identity stream・未知のmapは`cidMappingUnsupported`。初期段階では内部編集対象外。将来mapを実装してもfixtures・再読込で証明する |
| embedded subset font | 実フォントプログラム、使用codeとglyph、幅を取得できる。subset名や埋め込みの有無だけでは判定しない | subsetに新字がない、cmap・font programが読めない場合は`fontProgramUnavailable`。必要なら別フォントを埋め込む方式を後続で実証する |
| replacement glyph coverage | 置換全文と再描画対象のprefix/suffix全文に有効glyphとメトリクスがあり、missing glyphがない | `replacementGlyphMissing`。overlayの代替フォントでも全文字を検証し、欠落するなら拒否 |
| mixed font / style | 単一font・size・color・描画mode・stateの範囲。初期対応ではstyle境界をまたがない | `mixedTextStyle`。overlayでも異なるstyleの後続文字を巻き込まない。安全な分割ができなければ拒否 |
| rotation / writing mode / marked content | 初期対象は水平横書き、標準的な行列で、clip・透明度・marked content等の意味を維持できる範囲 | 縦書き、傾斜・回転、ActualText/MCID/タグ構造、共有Form、特殊描画modeの未対応は`textStateUnsupported`。overlayでも安全性を証明できなければ拒否 |
| geometry / reflow | 置換幅・ベースライン・次の文字位置・隣接要素との非干渉が確認できる。初期段階では行やobjectをまたぐ自動reflowをしない | `geometryUnsafe`。overlayの行再描画でも不明文字、他font/style、画像・罫線・背景との重なりを検査し、判定不能は拒否。幅・UIの受入詳細は#13 |

複数条件が失敗したらすべての理由を保持する。内部編集が失敗した後に保存済みの半端な結果へoverlayを足さず、元文書から作り直す。判定から確定までに入力文字列、選択、元revisionが変われば再判定する。undo/redoにも選択の元情報・判定・実行計画を保持し、再open時のSDK handleを永続IDとして使わない。

## 後続実装の段階と受け入れ条件

### 今回完了する設計部分

- 現行overlayの制約、各候補のAPI・配布・費用・ライセンス出典を記録する。
- SDK決定を保留し、対応判定、fallback、編集拒否の境界を定める。
- 個人データを使わず、既存builderで日本語・実フォントを埋め込んだsubset・CID map・分割show operation・ToUnicode欠損のPDFを生成し、現行metadataとoverlayの境界をテストする。
- テストは現行経路の回帰確認であり、将来の内部編集gateを実装・検証した証拠とはしない。

### 段階1: 判定情報を追加する

元stream / operator / codeのprovenanceをスキャナへ追加し、未対応理由を表現する。ToUnicodeの「明示mapping」とASCII推定を区別し、CID mapのIdentity/非Identity/未知を区別する。現行の真偽値`isIdentityCIDToGID`だけでは未知の正当性を証明できない。内部編集の対応証明がない範囲はこの段階でも候補へ昇格させない。overlayの危険条件では拒否理由をUIと書き出しへ伝播させる。

受入: すべての表の境界に理由付きfixtureがあり、不明な文字を黙って削除・推定せず、選択・確定・保存で同一判定を使う。

### 段階2: SDKを固定して限定実証する

選定候補のversion/revision、build構成、依存ライセンス、arm64/x86_64の配布方針、署名・サイズ増分、更新責任を記録する。単一object全体・横書き・単一style等の限定ケースから、scannerとSDKの文字/object対応を比較する。PDFiumを採る場合も`FPDFText_SetText`成功だけでは合格にしない。

受入: 同じ生成fixtureをSDKで変更→保存→再openし、置換後の抽出文字、glyph coverage、元文字の残存、隣接文字位置・非テキスト要素、preview/export一致を確認する。定量的なgeometry許容値は#13と整合させて先に固定する。失敗・保存エラー・判定不能で元文書を変更しないこと、overlayへのやり直しまたは拒否、undo/redoを検証する。

### 段階3: 混合経路を有効化する

証明できた限定範囲だけ内部編集へ送り、同じ文書の他範囲にはoverlay/unsupportedを適用する。異なる経路の編集が重なる場合や、先の変更が後の対象を無効にする場合は、元情報で再照合できなければ拒否する。複数ページ・保存し直し・印刷・undo/redoの整合性を確認してから対象を広げる。

受入: 対応範囲を利用者へ明示し、overlayであること・原文が残る可能性・拒否理由がわかる。100%の任意PDF対応や文書全体のreflowは約束しない。暗号化・権限制限・電子署名文書の扱いも導入前に別途定める。

## 他Issueとの境界

- #9（墨消し）: overlayは秘匿・情報削除を保証しない。内部編集も原文やmetadata、過去revision等の除去を自動的に保証しない。墨消し専用の契約・残存検証は#9で扱う。
- #13（幅とUI受入）: 日本語で幅が増える場合の見た目、選択範囲、幅制約・入力体験の具体値は#13で扱う。本設計の安全性証明に必要な非干渉条件は共有する。

## 生成fixtureの証跡

`Tests/PDFTextEditorTests/PDFHybridEditingBoundaryTests.swift`で実行時に生成し、終了時に削除する。`RawPDFBuilder`で日本語のToUnicode、人工的なsubset名、非Identity CID map、分割Tj/TJ、ToUnicode欠損を制御する。さらに`SyntheticFixture`と同梱Noto Sans JPを使い、Quartzが生成する実フォント埋め込みsubsetを含む日本語PDFを検証する。この実フォントfixtureは埋め込みプログラムと3つの視覚glyphを作る一方、ToUnicodeを含まず現行scannerの文字列は空になることを示す。別の合成fixtureで日本語ToUnicodeの読取を検証する。subset内にない新しい文字へのcoverageやSDKでの保存・再読込は後続の受入に残す。

ToUnicode欠損のType0 fixtureは現在の空文字・行再描画不可という境界を記録する。現在のアプリ全体が`unsupported`を強制できると主張するテストではなく、その拒否gateは段階1の受入条件である。

## 公式資料

すべて2026-10-21に確認。`main`や価格ページは変化するため、導入時は固定revision・契約内容で再確認する。

[pdfium-edit]: https://pdfium.googlesource.com/pdfium/+/refs/heads/main/public/fpdf_edit.h
[pdfium-build]: https://pdfium.googlesource.com/pdfium/+/refs/heads/main/README.md
[pdfium-license]: https://pdfium.googlesource.com/pdfium/+/refs/heads/main/LICENSE
[apryse-edit]: https://docs.apryse.com/core/guides/features/edit/replace/php
[apryse-mac]: https://docs.apryse.com/core/guides/get-started/mac/
[apryse-price]: https://apryse.com/pricing
[pdfium-github]: https://github.com/chromium/pdfium
[nutrient-content]: https://www.nutrient.io/sdk/content-editor/
[nutrient-mac]: https://www.nutrient.io/guides/macos/
[nutrient-price]: https://www.nutrient.io/sdk/pricing/
[nutrient-try]: https://www.nutrient.io/sdk/try
[mupdf-stream]: https://mupdf.readthedocs.io/en/1.28.5/_static/generated/c/html/xref_8h_source.html
[mupdf-build]: https://mupdf.readthedocs.io/en/1.28.1/guide/install.html
[artifex-license]: https://artifex.com/licensing

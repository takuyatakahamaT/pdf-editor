import AppKit
import Foundation
import PDFKit

/// 編集方式はここだけで決定する。UIは通常の文字編集として同じ操作を使う。
enum PDFTextEditPlanner {
    static func storage(sourceURL: URL, edit: ReplacementEdit) -> PDFTextReplacementStorage {
        guard edit.destinationOrigin == nil, !edit.composesLineEdits else {
            return .overlay(reason: "行再配置を含む編集")
        }
        switch PDFInternalTextEditEngine.eligibility(sourceURL: sourceURL, edit: edit) {
        case .supported:
            return .internalPDFium
        case .unsupported(let reason):
            // subsetに新しい漢字が無い場合や、書体/サイズを指定した場合も、
            // 原本の文字を正確に除去できれば背景を塗らずCoreTextで組版できる。
            if !edit.replacement.isEmpty,
               case .supported = PDFInternalTextEditEngine.eligibility(
                   sourceURL: sourceURL, edit: edit.sourceRemoval()
               ) {
                return .reconstructed
            }
            return .overlay(reason: reason)
        }
    }

    static func previewDocument(sourceURL: URL, edits: [ReplacementEdit]) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-editor-edit-plan-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFExportEngine.export(sourceURL: sourceURL, edits: edits, to: url)
        guard let document = PDFDocument(data: try Data(contentsOf: url)) else {
            throw PDFExportError.unreadableSource
        }
        return document
    }

    /// 透明再描画後の文字を、別の場所の同じ文言ではなく編集座標で確認する。
    static func verifyForeground(in outputURL: URL, edits: [ReplacementEdit]) throws {
        guard let document = PDFDocument(url: outputURL) else { throw PDFExportError.unreadableSource }
        for edit in edits where edit.storage.needsForeground {
            guard let page = document.page(at: edit.pageIndex) else { throw PDFExportError.unreadableSource }
            let index = PDFGlyphIndex.makeIndex(for: page)
            let emitted = try PDFTextRenderer.emittedGlyphs(for: edit)
            let glyphs = index.runs.flatMap(\.glyphs)
            // 元の文字枠やinkの高さには依存しない。句読点や大幅なサイズ変更も、
            // rendererが確定した各glyphの原点・サイズ・Unicodeで照合する。
            guard emitted.map(\.text).joined() == edit.replacement,
                  emitted.allSatisfy({ expected in
                      glyphs.filter { glyph in
                          glyph.isVisible && !glyph.isInsideForm && glyph.text == expected.text
                              && abs(glyph.advanceBox.minX - expected.origin.x) <= 0.05
                              && abs(glyph.baseline - expected.origin.y) <= 0.05
                              && abs(glyph.fontSize - expected.fontSize) <= 0.05
                      }.count == 1
                  }) else {
                throw PDFInternalTextEditError.failed("変更した文字を保存結果から確認できませんでした。")
            }
        }
    }
}

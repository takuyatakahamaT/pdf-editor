import Foundation

/// テスト専用: 最小構成の PDF を手組みで生成する。
/// `BDC`/`EMC`（marked content）の正確な構造をテストするには、
/// `CTLineDraw` 経由の生成（Quartz 自身がどう書き出すか次第で ToUnicode や
/// marked content の有無が変わってしまう）では制御しきれないため、
/// content stream を直接書いて xref テーブルまで組み立てる。
enum RawPDFBuilder {
    /// `objects[i]` は「i+1 番目のオブジェクト」の中身（`<< ... >>` や `N 0 obj` の
    /// 前後を含まない、辞書やストリーム本体だけ）。`build` が `N 0 obj ... endobj` と
    /// xref/trailer を組み立てる。
    static func build(objects: [String], rootObjectNumber: Int = 1) -> URL {
        var output = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(output.utf8.count)
            output += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = output.utf8.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        output += xref
        output += "trailer\n<< /Size \(objects.count + 1) /Root \(rootObjectNumber) 0 R >>\n"
        output += "startxref\n\(xrefOffset)\n%%EOF"

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-text-bench-raw-\(UUID().uuidString).pdf")
        try? Data(output.utf8).write(to: url)
        return url
    }

    /// `<< dict >>\nstream\n...\nendstream` 形式のオブジェクト本体を作る。
    /// `/Length` は実バイト数から自動計算する。
    static func streamObject(dict: String, streamContent: String) -> String {
        let length = streamContent.utf8.count
        return "<< \(dict) /Length \(length) >>\nstream\n\(streamContent)\nendstream"
    }

    /// 1 ページだけの最小 PDF（Helvetica 単純フォント 1 個、`/Widths` は宣言しない）を、
    /// 呼び出し側が渡した content stream 本文で作る。
    static func singlePagePDF(pageBounds: CGRect, cropBox: CGRect? = nil, contentStream: String) -> URL {
        let cropBoxEntry = cropBox.map {
            "/CropBox [\($0.minX) \($0.minY) \($0.maxX) \($0.maxY)] "
        } ?? ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R "
                + "/MediaBox [\(pageBounds.minX) \(pageBounds.minY) \(pageBounds.maxX) \(pageBounds.maxY)] "
                + cropBoxEntry
                + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            streamObject(dict: "", streamContent: contentStream)
        ]
        return build(objects: objects)
    }

    static func multiPagePDF(pages: [(bounds: CGRect, content: String)]) -> URL {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        var pageReferences: [String] = []
        for page in pages {
            let pageObject = objects.count + 1
            let contentObject = pageObject + 1
            pageReferences.append("\(pageObject) 0 R")
            objects.append(
                "<< /Type /Page /Parent 2 0 R "
                    + "/MediaBox [\(page.bounds.minX) \(page.bounds.minY) \(page.bounds.maxX) \(page.bounds.maxY)] "
                    + "/Resources << /Font << /F1 \(pages.count * 2 + 3) 0 R >> >> "
                    + "/Contents \(contentObject) 0 R >>"
            )
            objects.append(streamObject(dict: "", streamContent: page.content))
        }
        objects[1] = "<< /Type /Pages /Kids [\(pageReferences.joined(separator: " "))] /Count \(pages.count) >>"
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        return build(objects: objects)
    }
}

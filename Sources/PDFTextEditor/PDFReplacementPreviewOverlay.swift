import AppKit
import PDFKit

/// Draws the same page annotations used by the live PDFView overlay. Kept separate from the
/// view so acceptance tests exercise the exact preview renderer at multiple raster scales.
enum ReplacementPreviewRenderer {
    static func draw(on page: PDFPage, in context: CGContext) {
        let annotations = page.annotations
        for annotation in annotations {
            guard let cover = annotation as? ReplacementCoverAnnotation else { continue }
            cover.drawPreview(in: context)
        }
        for annotation in annotations {
            guard let replacement = annotation as? ReplacementTextAnnotation else { continue }
            replacement.drawPreview(in: context)
        }
    }
}

/// Replacement annotations stay attached to PDF pages for hit testing and edit history, but PDFKit
/// caches their appearance at the page's initial display scale. This provider draws them in native
/// page overlay views so glyph outlines are rendered again at the current zoom and backing scale.
@MainActor
final class ReplacementPreviewOverlayProvider: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private final class WeakOverlay {
        weak var view: ReplacementPreviewPageOverlayView?

        init(_ view: ReplacementPreviewPageOverlayView) {
            self.view = view
        }
    }

    private var overlays: [ObjectIdentifier: WeakOverlay] = [:]
    private var revision = -1

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let view = view as? ClickablePDFView else { return nil }
        let overlay = ReplacementPreviewPageOverlayView(page: page, pdfView: view)
        overlays[ObjectIdentifier(page)] = WeakOverlay(overlay)
        return overlay
    }

    func invalidate(revision: Int) {
        guard self.revision != revision else { return }
        self.revision = revision
        overlays = overlays.filter { $0.value.view != nil }
        for overlay in overlays.values {
            overlay.view?.needsDisplay = true
        }
    }

    func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        overlays.removeValue(forKey: ObjectIdentifier(page))
    }
}

@MainActor
private final class ReplacementPreviewPageOverlayView: NSView {
    private let page: PDFPage
    private weak var pdfView: ClickablePDFView?

    init(page: PDFPage, pdfView: ClickablePDFView) {
        self.page = page
        self.pdfView = pdfView
        super.init(frame: .zero)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let context = NSGraphicsContext.current?.cgContext,
              let pageToOverlay = pageToOverlayTransform(in: pdfView) else { return }

        context.saveGState()
        context.concatenate(pageToOverlay)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        ReplacementPreviewRenderer.draw(on: page, in: context)
        context.restoreGState()
    }

    private func pageToOverlayTransform(in pdfView: ClickablePDFView) -> CGAffineTransform? {
        func convert(_ point: CGPoint) -> CGPoint {
            let inPDFView = pdfView.convert(point, from: page)
            return self.convert(inPDFView, from: pdfView)
        }

        let origin = convert(.zero)
        let xAxis = convert(CGPoint(x: 1, y: 0))
        let yAxis = convert(CGPoint(x: 0, y: 1))
        let transform = CGAffineTransform(
            a: xAxis.x - origin.x,
            b: xAxis.y - origin.y,
            c: yAxis.x - origin.x,
            d: yAxis.y - origin.y,
            tx: origin.x,
            ty: origin.y
        )
        guard transform.a.isFinite, transform.b.isFinite, transform.c.isFinite,
              transform.d.isFinite, transform.tx.isFinite, transform.ty.isFinite else { return nil }
        return transform
    }
}

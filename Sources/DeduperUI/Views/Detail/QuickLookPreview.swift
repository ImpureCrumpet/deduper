import SwiftUI
import Quartz

/// Embedded Quick Look preview via NSViewRepresentable.
/// Safer than QLPreviewPanel (no responder chain issues in SwiftUI).
public struct QuickLookPreview: NSViewRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(
        context: Context
    ) -> QLPreviewView {
        let view = QLPreviewView(
            frame: .zero, style: .normal
        )!
        view.previewItem = url as QLPreviewItem
        return view
    }

    public func updateNSView(
        _ view: QLPreviewView,
        context: Context
    ) {
        view.previewItem = url as QLPreviewItem
    }
}

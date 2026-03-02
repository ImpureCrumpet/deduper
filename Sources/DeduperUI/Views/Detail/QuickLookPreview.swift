import SwiftUI
import Quartz

/// Embedded Quick Look preview via NSViewRepresentable.
/// Uses a plain NSView wrapper so the Swift runtime can resolve the
/// NSViewType associated type without triggering the QLPreviewView
/// metadata crash on macOS 26 (rdar://Swift runtime getSuperclassMetadata).
public struct QuickLookPreview: NSViewRepresentable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let preview = QLPreviewView(
            frame: .zero, style: .normal
        ) {
            preview.previewItem = url as QLPreviewItem
            preview.autoresizingMask = [.width, .height]
            preview.frame = container.bounds
            container.addSubview(preview)
        }
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let preview = nsView.subviews.first
                as? QLPreviewView else { return }
        if (preview.previewItem as? URL) != url {
            preview.previewItem = url as QLPreviewItem
        }
    }
}

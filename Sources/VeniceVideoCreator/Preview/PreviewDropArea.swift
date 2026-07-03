import AppKit
import SwiftUI

/// AppKit drop target spanning the preview canvas (per the repo drop rule).
/// Hit-test transparent so pointer interactions beneath keep working.
struct PreviewDropArea: NSViewRepresentable {
    let onAssetPayload: (String) -> Void
    let onFileURLs: ([URL]) -> Void

    func makeNSView(context: Context) -> PreviewDropNSView {
        let view = PreviewDropNSView()
        view.onAssetPayload = onAssetPayload
        view.onFileURLs = onFileURLs
        return view
    }

    func updateNSView(_ nsView: PreviewDropNSView, context: Context) {
        nsView.onAssetPayload = onAssetPayload
        nsView.onFileURLs = onFileURLs
    }
}

final class PreviewDropNSView: NSView {
    var onAssetPayload: ((String) -> Void)?
    var onFileURLs: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, .fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Drag routing uses registered types, not hitTest; nil keeps clicks passing through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = sender.draggingPasteboard.string(forType: .string) != nil
            || !fileURLs(sender).isEmpty
        return accepts ? .copy : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let payload = sender.draggingPasteboard.string(forType: .string) {
            onAssetPayload?(payload)
            return true
        }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onFileURLs?(urls)
        return true
    }
}

import AppKit
import SwiftUI

/// AppKit drop target spanning the preview canvas (per the repo drop rule).
/// Hit-test transparent so pointer interactions beneath keep working.
struct PreviewDropArea: NSViewRepresentable {
    let onAssetPayload: (String) -> Void
    let onFileURLs: ([URL]) -> Void

    func makeNSView(context: Context) -> NativeDropHostingView<EmptyView> {
        let view = NativeDropHostingView(rootView: EmptyView())
        view.passthroughHitTest = true
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NativeDropHostingView<EmptyView>, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NativeDropHostingView<EmptyView>) {
        let onAssetPayload = onAssetPayload
        let onFileURLs = onFileURLs
        view.accepts = { sender in
            // Accept on advertised type, not value: SwiftUI .draggable(String) fulfills the
            // string promise lazily, so it's nil at drag-enter. The payload is read at drop.
            let pb = sender.draggingPasteboard
            return pb.availableType(from: [.string]) != nil
                || pb.availableType(from: [.fileURL]) != nil
        }
        view.perform = { sender in
            if let payload = sender.draggingPasteboard.string(forType: .string) {
                onAssetPayload(payload)
                return true
            }
            let urls = sender.droppedFileURLs
            guard !urls.isEmpty else { return false }
            onFileURLs(urls)
            return true
        }
    }
}

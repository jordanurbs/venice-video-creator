import AppKit
import SwiftUI

struct MediaPanelDropArea<Content: View>: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: (_ urls: [URL]) -> Void
    var onTextDrop: ((String) -> Void)?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NativeDropHostingView<Content> {
        let view = NativeDropHostingView(rootView: content())
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NativeDropHostingView<Content>, context: Context) {
        nsView.rootView = content()
        configure(nsView)
    }

    private func configure(_ view: NativeDropHostingView<Content>) {
        view.onTargetChanged = { isTargeted = $0 }
        let onDrop = onDrop
        let onTextDrop = onTextDrop
        view.accepts = { sender in
            // Accept on advertised type, not value: SwiftUI .draggable(String) fulfills the
            // string promise lazily, so it's nil at drag-enter. The payload is read at drop.
            let pb = sender.draggingPasteboard
            return pb.availableType(from: [.fileURL]) != nil
                || (onTextDrop != nil && pb.availableType(from: [.string]) != nil)
        }
        view.perform = { sender in
            let urls = sender.droppedFileURLs
            if !urls.isEmpty {
                onDrop(urls)
                return true
            }
            if let onTextDrop, let text = sender.draggingPasteboard.string(forType: .string) {
                onTextDrop(text)
                return true
            }
            return false
        }
    }
}

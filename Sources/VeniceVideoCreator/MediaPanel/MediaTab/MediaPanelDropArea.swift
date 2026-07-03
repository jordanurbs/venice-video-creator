import AppKit
import SwiftUI

struct MediaPanelDropArea<Content: View>: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: (_ urls: [URL]) -> Void
    var onTextDrop: ((String) -> Void)?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> DropHostingView<Content> {
        let view = DropHostingView(rootView: content())
        view.onTargetChanged = { isTargeted = $0 }
        view.onDrop = onDrop
        view.onTextDrop = onTextDrop
        return view
    }

    func updateNSView(_ nsView: DropHostingView<Content>, context: Context) {
        nsView.rootView = content()
        nsView.onTargetChanged = { isTargeted = $0 }
        nsView.onDrop = onDrop
        nsView.onTextDrop = onTextDrop
    }
}

final class DropHostingView<Content: View>: NSHostingView<Content> {
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onTextDrop: ((String) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .string])
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !fileURLs(sender).isEmpty
            || (onTextDrop != nil && sender.draggingPasteboard.string(forType: .string) != nil)
        guard accepts else { return [] }
        onTargetChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        let urls = fileURLs(sender)
        if !urls.isEmpty {
            onDrop?(urls)
            return true
        }
        if let onTextDrop, let text = sender.draggingPasteboard.string(forType: .string) {
            onTextDrop(text)
            return true
        }
        return false
    }
}

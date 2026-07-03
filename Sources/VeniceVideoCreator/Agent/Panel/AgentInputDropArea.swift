import AppKit
import SwiftUI

/// AppKit drop target for the agent input box (spans a TextEditor, so per the
/// repo drop rule it must be AppKit). Accepts in-app `venice-asset://` drags and
/// Finder files; plain text drags fall through to the text view.
struct AgentInputDropArea<Content: View>: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onAssetIds: ([String]) -> Void
    let onFileURLs: ([URL]) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> AgentInputDropHostingView<Content> {
        let view = AgentInputDropHostingView(rootView: content())
        view.onTargetChanged = { isTargeted = $0 }
        view.onAssetIds = onAssetIds
        view.onFileURLs = onFileURLs
        return view
    }

    func updateNSView(_ nsView: AgentInputDropHostingView<Content>, context: Context) {
        nsView.rootView = content()
        nsView.onTargetChanged = { isTargeted = $0 }
        nsView.onAssetIds = onAssetIds
        nsView.onFileURLs = onFileURLs
    }
}

final class AgentInputDropHostingView<Content: View>: NSHostingView<Content> {
    var onTargetChanged: ((Bool) -> Void)?
    var onAssetIds: (([String]) -> Void)?
    var onFileURLs: (([URL]) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .string])
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func assetIds(_ sender: any NSDraggingInfo) -> [String] {
        guard let payload = sender.draggingPasteboard.string(forType: .string) else { return [] }
        return payload.split(separator: "\n").compactMap { MediaTab.assetId(fromDragString: String($0)) }
    }

    private func fileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !assetIds(sender).isEmpty || !fileURLs(sender).isEmpty else { return [] }
        onTargetChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        let ids = assetIds(sender)
        if !ids.isEmpty {
            onAssetIds?(ids)
            return true
        }
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onFileURLs?(urls)
        return true
    }
}

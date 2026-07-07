import AppKit
import SwiftUI

/// AppKit drop target for the agent input box; accepts asset + Finder-file drags, plain text falls through.
struct AgentInputDropArea<Content: View>: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onAssetIds: ([String]) -> Void
    let onFileURLs: ([URL]) -> Void
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

    private static func assetIds(_ sender: any NSDraggingInfo) -> [String] {
        guard let payload = sender.draggingPasteboard.string(forType: .string) else { return [] }
        return payload.split(separator: "\n").compactMap { MediaTab.assetId(fromDragString: String($0)) }
    }

    private func configure(_ view: NativeDropHostingView<Content>) {
        view.onTargetChanged = { isTargeted = $0 }
        let onAssetIds = onAssetIds
        let onFileURLs = onFileURLs
        view.accepts = { sender in
            let pb = sender.draggingPasteboard
            if pb.availableType(from: [.fileURL]) != nil { return true }
            // A resolved string is external plain text (falls through); in-app .draggable asset drags resolve only at drop, so an advertised-but-empty type is an asset drag.
            if let payload = pb.string(forType: .string) {
                return payload.split(separator: "\n").contains { MediaTab.assetId(fromDragString: String($0)) != nil }
            }
            return pb.availableType(from: [.string]) != nil
        }
        view.perform = { sender in
            let ids = Self.assetIds(sender)
            if !ids.isEmpty {
                onAssetIds(ids)
                return true
            }
            let urls = sender.droppedFileURLs
            guard !urls.isEmpty else { return false }
            onFileURLs(urls)
            return true
        }
    }
}

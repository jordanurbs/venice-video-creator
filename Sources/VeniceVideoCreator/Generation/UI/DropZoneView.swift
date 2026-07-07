import AppKit
import SwiftUI

extension NSDraggingInfo {
    /// File URLs on the drag pasteboard (Finder drops); empty for non-file drags.
    @MainActor var droppedFileURLs: [URL] {
        (draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }
}

/// Single native AppKit drop host for every drop target in the app. Type
/// registration, target reporting, and the drag lifecycle live here; the two
/// bits that differ per site — whether a drag is accepted and how a drop is
/// handled — are supplied as closures so each call site keeps its exact
/// behavior. `passthroughHitTest` makes it a transparent overlay that lets
/// clicks reach the content beneath (used by the preview + generation zones).
final class NativeDropHostingView<Content: View>: NSHostingView<Content> {
    var accepts: ((any NSDraggingInfo) -> Bool)?
    var perform: ((any NSDraggingInfo) -> Bool)?
    var onTargetChanged: ((Bool) -> Void)?
    var passthroughHitTest = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .string])
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passthroughHitTest ? nil : super.hitTest(point)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard accepts?(sender) ?? false else { return [] }
        onTargetChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        return perform?(sender) ?? false
    }
}

/// Transparent native AppKit drop target.
struct DropTargetOverlay: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onDrop: (String) -> Void
    var onFileDrop: (([URL]) -> Void)?

    init(
        isTargeted: Binding<Bool>,
        onDrop: @escaping (String) -> Void,
        onFileDrop: (([URL]) -> Void)? = nil
    ) {
        self._isTargeted = isTargeted
        self.onDrop = onDrop
        self.onFileDrop = onFileDrop
    }

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
        view.onTargetChanged = { isTargeted = $0 }
        let onDrop = onDrop
        let onFileDrop = onFileDrop
        view.accepts = { sender in
            let pb = sender.draggingPasteboard
            return pb.availableType(from: [.string]) != nil
                || (onFileDrop != nil && pb.availableType(from: [.fileURL]) != nil)
        }
        view.perform = { sender in
            if let payload = sender.draggingPasteboard.string(forType: .string) {
                Log.generation.notice("drop perform payloadLen=\(payload.count) tail=\(payload.suffix(60))")
                onDrop(payload)
                return true
            }
            let urls = sender.droppedFileURLs
            if !urls.isEmpty, let onFileDrop {
                onFileDrop(urls)
                return true
            }
            Log.generation.notice("drop perform: no usable payload")
            return false
        }
    }
}

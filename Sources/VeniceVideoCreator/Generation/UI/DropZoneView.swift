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

    func makeNSView(context: Context) -> DropTargetNSView {
        let view = DropTargetNSView()
        view.onTargetChanged = { isTargeted = $0 }
        view.onDrop = onDrop
        view.onFileDrop = onFileDrop
        return view
    }

    func updateNSView(_ nsView: DropTargetNSView, context: Context) {
        nsView.onTargetChanged = { isTargeted = $0 }
        nsView.onDrop = onDrop
        nsView.onFileDrop = onFileDrop
    }
}

final class DropTargetNSView: NSView {
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: ((String) -> Void)?
    var onFileDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, .fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Drag routing uses registered types, not hitTest; nil lets clicks reach the
    // SwiftUI drop zone underneath (so tapping it can open the import panel).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Accept on advertised type, not value: SwiftUI .draggable(String) fulfills the
        // string promise lazily, so it's nil at drag-enter. The payload is read at drop.
        let pb = sender.draggingPasteboard
        let accepts = pb.availableType(from: [.string]) != nil
            || (onFileDrop != nil && pb.availableType(from: [.fileURL]) != nil)
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
        if let payload = sender.draggingPasteboard.string(forType: .string) {
            Log.generation.notice("drop perform payloadLen=\(payload.count) tail=\(payload.suffix(60))")
            onDrop?(payload)
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

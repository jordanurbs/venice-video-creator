import AppKit
import SwiftUI

/// Reference-image thumbnail that resolves its picture off the main thread and
/// caches it. It never does a synchronous full-resolution `NSImage(contentsOf:)`
/// decode in a view body — that path, multiplied across many references and
/// re-run on every media change during bulk cast/location generation, saturated
/// the main thread. The caller supplies the placeholder (progress / icon) and
/// applies its own frame, clip, and overlays.
struct ReferenceThumbnail<Placeholder: View>: View {
    @Environment(EditorViewModel.self) private var editor
    let assetId: String
    var maxPixelSize: Int = 320
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: reloadKey) { await load() }
    }

    /// Re-runs the loader when the asset first gets a decoded thumbnail (i.e. its
    /// generation finished), so a placeholder swaps to the real image on its own.
    private var reloadKey: String {
        let ready = editor.mediaAssets.first(where: { $0.id == assetId })?.thumbnail != nil
        return "\(assetId)|\(ready)"
    }

    private func load() async {
        if let loaded = await CharacterThumbs.loadThumbnail(for: assetId, editor: editor, maxPixelSize: maxPixelSize) {
            image = loaded
        }
    }
}

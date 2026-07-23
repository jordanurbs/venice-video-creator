import AppKit
import SwiftUI

/// The blurred backdrop shown behind a generating placeholder, built from the
/// generation's own reference image. Resolves the reference off the main thread
/// (cached) — never a synchronous full-resolution `NSImage(contentsOf:)` decode,
/// which, read every frame while a generation animates, beachballed the UI.
struct GeneratingReferenceBlur: View {
    @Environment(EditorViewModel.self) private var editor
    let asset: MediaAsset
    var blurRadius: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Color.clear
                    .overlay { Image(nsImage: image).resizable().scaledToFill().blur(radius: blurRadius) }
                    .clipped()
            }
        }
        .task(id: refKey) { await load() }
    }

    private var refIds: [String] {
        guard let input = asset.generationInput else { return [] }
        return (input.imageURLAssetIds ?? []) + (input.referenceImageAssetIds ?? [])
    }

    private var refKey: String { refIds.joined(separator: ",") }

    private func load() async {
        for id in refIds {
            guard let ref = editor.mediaAssets.first(where: { $0.id == id }), ref.type == .image else { continue }
            if let img = await CharacterThumbs.loadThumbnail(for: id, editor: editor, maxPixelSize: 320) {
                image = img
                return
            }
        }
    }
}

import AppKit

/// Shared lookups for character reference imagery. Menu icons are downscaled
/// and cached — NSMenu renders NSImages at their reported size, so full-res
/// generation outputs would blow the row height.
@MainActor
enum CharacterThumbs {
    private static var faceCache: [String: NSImage] = [:]
    /// Downsampled reference thumbnails keyed by asset id, populated off the main
    /// thread. Guards against the synchronous full-res `NSImage(contentsOf:)`
    /// decode that beachballed the main thread during bulk cast/location generation.
    private static var thumbCache: [String: NSImage] = [:]

    /// The asset's thumbnail, falling back to decoding the file on disk.
    /// Synchronous — use only off the render path (e.g. menu icons). View bodies
    /// must go through `ReferenceThumbnail` / `loadThumbnail` instead.
    static func image(for assetId: String, editor: EditorViewModel) -> NSImage? {
        guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }),
              asset.type == .image else { return nil }
        if let thumb = asset.thumbnail { return thumb }
        return NSImage(contentsOf: asset.url)
    }

    /// A previously loaded reference thumbnail, if cached. Cheap and synchronous —
    /// safe to read in a view body for an instant first paint.
    static func cachedThumbnail(for assetId: String) -> NSImage? { thumbCache[assetId] }

    /// Returns a downsampled thumbnail for a reference asset, decoding off the
    /// main thread and caching the result. Prefers the asset's already-decoded
    /// `thumbnail`; never performs a synchronous full-resolution decode. Returns
    /// nil while the asset's file isn't readable yet (still generating).
    static func loadThumbnail(for assetId: String, editor: EditorViewModel, maxPixelSize: Int = 320) async -> NSImage? {
        if let cached = thumbCache[assetId] { return cached }
        guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }),
              asset.type == .image else { return nil }
        if let thumb = asset.thumbnail {
            thumbCache[assetId] = thumb
            return thumb
        }
        let url = asset.url
        let side = max(64, maxPixelSize)
        let cg = await Task.detached(priority: .utility) {
            ImageEncoder.thumbnail(url: url, maxPixelSize: side)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache[assetId] = image
        return image
    }

    /// A small square face icon for a character (locked reference when set,
    /// else the first ready reference image).
    static func face(for character: CharacterSpec, editor: EditorViewModel, side: CGFloat = 20) -> NSImage? {
        let key = "\(character.id)-\(character.lockedReferenceAssetId ?? "any")-\(Int(side))"
        if let cached = faceCache[key] { return cached }
        for aid in character.activeReferenceAssetIds {
            guard let source = image(for: aid, editor: editor) else { continue }
            let icon = squareIcon(source, side: side)
            faceCache[key] = icon
            return icon
        }
        return nil
    }

    private static func squareIcon(_ source: NSImage, side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let icon = NSImage(size: target)
        icon.lockFocus()
        defer { icon.unlockFocus() }
        let srcSize = source.size
        // Aspect-fill crop rect in source coordinates.
        let scale = max(target.width / max(srcSize.width, 1), target.height / max(srcSize.height, 1))
        let cropW = target.width / scale
        let cropH = target.height / scale
        let src = NSRect(
            x: (srcSize.width - cropW) / 2,
            y: (srcSize.height - cropH) / 2,
            width: cropW, height: cropH
        )
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: target), xRadius: 4, yRadius: 4)
        path.addClip()
        source.draw(in: NSRect(origin: .zero, size: target), from: src, operation: .sourceOver, fraction: 1)
        return icon
    }
}

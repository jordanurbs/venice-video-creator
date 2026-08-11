import AppKit
import SwiftUI

/// "From library" menu shared by every reference-image pane — character and
/// location inspectors, the Cast/Locations panel rows, and the generation
/// panel's reference slots. Lists library images not already attached (newest
/// first, capped so the menu stays usable on big projects) so the user can
/// attach references themselves instead of relying on the agent.
struct LibraryReferencePicker: View {
    @Environment(EditorViewModel.self) private var editor

    /// Asset ids already attached wherever this picker feeds — excluded from
    /// the menu so the same image can't be attached twice.
    let excludedAssetIds: Set<String>
    /// Compact renders an icon-only button (for tight panel rows).
    var compact: Bool = false
    let onPick: (MediaAsset) -> Void

    var body: some View {
        Menu {
            LibraryReferenceMenuItems(
                excludedAssetIds: excludedAssetIds,
                onPick: onPick
            )
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: AppTheme.FontSize.xxs))
                if !compact {
                    Text("From library")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Attach an existing image from the media library as a reference")
    }
}

/// The menu rows themselves, reusable inside any `Menu` or `contextMenu` —
/// the generation panel embeds these under its drop-zone context menus.
struct LibraryReferenceMenuItems: View {
    @Environment(EditorViewModel.self) private var editor

    let excludedAssetIds: Set<String>
    /// Library asset types offered; reference panes want images only, the
    /// generation panel's unified strip also takes videos and audio.
    var acceptedTypes: Set<ClipType> = [.image]
    let onPick: (MediaAsset) -> Void

    private static let menuCap = 30

    private var candidates: [MediaAsset] {
        editor.mediaAssets
            .filter { acceptedTypes.contains($0.type) && !excludedAssetIds.contains($0.id) && !$0.isGenerating }
            .sorted { sortDate($0) > sortDate($1) }
    }

    private func sortDate(_ asset: MediaAsset) -> Date {
        asset.generationInput?.createdAt ?? asset.importInput?.createdAt ?? .distantPast
    }

    var body: some View {
        let items = Array(candidates.prefix(Self.menuCap))
        if items.isEmpty {
            Text(acceptedTypes == [.image]
                ? "No other images in the library"
                : "No matching media in the library")
        } else {
            ForEach(items, id: \.id) { asset in
                Button {
                    onPick(asset)
                } label: {
                    if let thumb = asset.thumbnail,
                       let menuImage = Self.menuThumbnail(from: thumb) {
                        Label {
                            Text(displayName(asset))
                        } icon: {
                            Image(nsImage: menuImage)
                        }
                    } else {
                        Label(displayName(asset), systemImage: asset.type.sfSymbolName)
                    }
                }
            }
            if candidates.count > Self.menuCap {
                Divider()
                Button("Show all in Media…") {
                    editor.showMediaPanelMediaTab()
                }
            }
        }
    }

    private func displayName(_ asset: MediaAsset) -> String {
        asset.name.isEmpty ? String(asset.id.prefix(8)) : asset.name
    }

    /// Small square render for the menu row; menus draw NSImages at their
    /// natural size, so downscale here.
    private static func menuThumbnail(from image: NSImage, side: CGFloat = 24) -> NSImage? {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return nil }
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        defer { out.unlockFocus() }
        // Aspect-fill crop into the square.
        let scale = max(side / source.width, side / source.height)
        let drawSize = NSSize(width: source.width * scale, height: source.height * scale)
        let origin = NSPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        image.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        return out
    }
}

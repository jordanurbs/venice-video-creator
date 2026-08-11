import AppKit
import SwiftUI

/// Left-dock tab for the production's locations: every setting in the shot
/// plan with its reference plates and a [re]generate action. Mirrors CastPanel.
struct LocationsPanel: View {
    @Environment(EditorViewModel.self) private var editor

    private var locations: [LocationSpec] { editor.shotPlan?.locations ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            if locations.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(locations) { location in
                            LocationRow(
                                location: location,
                                isSelected: editor.selectedLocationId == location.id,
                                onSelect: { editor.selectLocation(id: location.id) }
                            )
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Locations")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: 0)
            if !locations.isEmpty {
                Text("\(locations.count)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("No locations yet.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Ask the agent to create the production's settings. Reference plates keep environments consistent across shots and appear here.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
    }
}

// MARK: - Location row

private struct LocationRow: View {
    @Environment(EditorViewModel.self) private var editor
    let location: LocationSpec
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var confirmingRegenerate = false
    @State private var confirmingPlateDeletion: String?
    @State private var hoveredPlate: String?
    @FocusState private var focusedPlate: String?

    /// Only ids that resolve to a live asset — ghost ids must not render as
    /// permanent blank plates (see CastRow.resolvedReferenceIds).
    private var resolvedReferenceIds: [String] {
        location.referenceImageAssetIds.filter { editor.mediaAssetsById[$0] != nil }
    }

    private var hasReferences: Bool { !resolvedReferenceIds.isEmpty }

    private var anyInFlight: Bool {
        location.referenceImageAssetIds.contains { isInFlight($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(location.name.isEmpty ? "Unnamed" : location.name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                libraryPicker
                regenerateButton
            }
            if let description = location.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(2)
            }
            if hasReferences {
                // The full angle ladder, labeled, large enough to judge that
                // every angle depicts the same coherent space BEFORE any
                // shot generation spends credits against it.
                HStack(alignment: .top, spacing: AppTheme.Spacing.xs) {
                    ForEach(resolvedReferenceIds, id: \.self) { aid in
                        plateCell(aid)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("No reference plates yet.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(
                    isSelected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : Color.clear,
                    lineWidth: AppTheme.BorderWidth.thin
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .confirmationDialog(
            "Regenerate reference plates for \(location.name.isEmpty ? "this location" : location.name)? This costs credits and replaces the current references (old images stay in the media library).",
            isPresented: $confirmingRegenerate,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                editor.regenerateLocationReferences(locationId: location.id)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove this reference plate from \(location.name.isEmpty ? "this location" : location.name)? It's deleted from the project and the media library. You can undo this.",
            isPresented: Binding(
                get: { confirmingPlateDeletion != nil },
                set: { if !$0 { confirmingPlateDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingPlateDeletion
        ) { assetId in
            Button("Remove plate", role: .destructive) {
                editor.removeLocationReference(locationId: location.id, assetId: assetId)
                if focusedPlate == assetId { focusedPlate = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// One reference plate: click to select, double-click to preview, and remove
    /// via the hover ✕, the context menu, or the delete/backspace key while
    /// selected — each routed through a confirmation.
    @ViewBuilder
    private func plateCell(_ aid: String) -> some View {
        let isFocused = focusedPlate == aid
        VStack(spacing: AppTheme.Spacing.xxs) {
            referenceThumb(aid)
                .overlay(alignment: .topLeading) { deletePlateButton(aid) }
            Text(angleLabel(aid))
                .font(.system(size: AppTheme.FontSize.micro))
                .foregroundStyle(isFocused ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .focusable()
        .focused($focusedPlate, equals: aid)
        .onHover { hoveredPlate = $0 ? aid : (hoveredPlate == aid ? nil : hoveredPlate) }
        .onTapGesture(count: 2) { openPreview(aid) }
        .onTapGesture { focusedPlate = aid }
        .onDeleteCommand { confirmingPlateDeletion = aid }
    }

    /// Small ✕ shown on hover or while the plate is selected — left-click deletes.
    @ViewBuilder
    private func deletePlateButton(_ aid: String) -> some View {
        if (hoveredPlate == aid || focusedPlate == aid), !isInFlight(aid) {
            Button {
                confirmingPlateDeletion = aid
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(AppTheme.Opacity.prominent)))
                    .padding(2)
            }
            .buttonStyle(.plain)
            .help("Remove this reference plate")
        }
    }

    private func openPreview(_ assetId: String) {
        if let asset = editor.mediaAssets.first(where: { $0.id == assetId }) {
            editor.openPreviewTab(for: asset)
        }
    }

    /// Compact "from library" picker so plates can be attached here directly,
    /// without the agent or a trip to the inspector.
    private var libraryPicker: some View {
        LibraryReferencePicker(
            excludedAssetIds: Set(location.referenceImageAssetIds),
            compact: true
        ) { asset in
            guard var updated = editor.location(id: location.id) else { return }
            if !updated.referenceImageAssetIds.contains(asset.id) {
                updated.referenceImageAssetIds.append(asset.id)
            }
            if updated.lockedReferenceAssetId == nil {
                updated.lockedReferenceAssetId = asset.id
            }
            editor.upsertLocation(updated)
        }
    }

    @ViewBuilder
    private var regenerateButton: some View {
        Button {
            if hasReferences {
                confirmingRegenerate = true
            } else {
                editor.regenerateLocationReferences(locationId: location.id)
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                if anyInFlight {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: hasReferences ? "arrow.clockwise" : "sparkles")
                        .font(.system(size: AppTheme.FontSize.xxs))
                }
                Text(hasReferences ? "Regenerate" : "Generate")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.plain)
        .disabled(anyInFlight)
        .help(hasReferences ? "Generate a fresh set of reference plates" : "Generate reference plates")
    }

    @ViewBuilder
    private func referenceThumb(_ assetId: String) -> some View {
        let isLocked = location.lockedReferenceAssetId == assetId
        let isFocused = focusedPlate == assetId
        let dimmed = location.lockedReferenceAssetId != nil && !isLocked
        ReferenceThumbnail(assetId: assetId, maxPixelSize: 160) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs).fill(Color.black)
                if isInFlight(assetId) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
        }
        .frame(width: 84, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        .opacity(dimmed ? AppTheme.Opacity.medium : 1)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .strokeBorder(
                    isFocused ? AppTheme.Accent.primary
                        : (isLocked ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : Color.clear),
                    lineWidth: isFocused ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.thin
                )
        )
        .overlay(alignment: .bottomTrailing) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: AppTheme.FontSize.micro))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .padding(2)
                    .background(Circle().fill(Color.black.opacity(AppTheme.Opacity.prominent)))
                    .padding(2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        .help(isLocked ? "Canonical look (locked) — double-click to preview" : "Click to select, double-click to preview")
        .contextMenu {
            Button("Preview") { openPreview(assetId) }
            if isLocked {
                Button("Unlock canonical look") { setLock(nil) }
            } else {
                Button("Lock as canonical look") { setLock(assetId) }
            }
            Button("Show in Media") { revealInMediaTab(assetId) }
            Divider()
            Button("Remove plate…", role: .destructive) { confirmingPlateDeletion = assetId }
        }
    }

    /// Short label for an angle thumb, derived from the ladder position by
    /// generation prompt (wide/medium/detail), falling back to the index.
    private func angleLabel(_ assetId: String) -> String {
        guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else { return "" }
        let p = (asset.generationInput?.prompt ?? "").lowercased()
        if p.contains("wide establishing") { return "wide" }
        if p.contains("medium shot") { return "medium" }
        if p.contains("detail shot") { return "detail" }
        if p.contains("reverse angle") { return "reverse" }
        let idx = location.referenceImageAssetIds.firstIndex(of: assetId) ?? 0
        return "ref \(idx + 1)"
    }

    private func setLock(_ assetId: String?) {
        guard var updated = editor.location(id: location.id) else { return }
        updated.lockedReferenceAssetId = assetId
        editor.upsertLocation(updated)
    }

    private func isInFlight(_ assetId: String) -> Bool {
        guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else { return false }
        switch asset.generationStatus {
        case .preparing, .generating, .downloading, .rendering: return true
        case .none, .failed, .cancelled: return false
        }
    }

    private func revealInMediaTab(_ assetId: String) {
        guard editor.mediaAssets.contains(where: { $0.id == assetId }) else { return }
        editor.selectedMediaAssetIds = [assetId]
        editor.showMediaPanelMediaTab()
        editor.mediaPanelRevealAssetId = assetId
    }
}

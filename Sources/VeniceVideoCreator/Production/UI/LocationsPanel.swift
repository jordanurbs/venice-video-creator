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

    private var hasReferences: Bool { !location.referenceImageAssetIds.isEmpty }

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
                regenerateButton
            }
            if let description = location.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(2)
            }
            if hasReferences {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(location.referenceImageAssetIds, id: \.self) { aid in
                        referenceThumb(aid)
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
        let dimmed = location.lockedReferenceAssetId != nil && !isLocked
        Button {
            if let asset = editor.mediaAssets.first(where: { $0.id == assetId }) {
                editor.openPreviewTab(for: asset)
            }
        } label: {
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
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .opacity(dimmed ? AppTheme.Opacity.medium : 1)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .strokeBorder(
                        isLocked ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : Color.clear,
                        lineWidth: AppTheme.BorderWidth.thin
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
        }
        .buttonStyle(.plain)
        .help(isLocked ? "Canonical look (locked) — click to preview" : "Click to preview")
        .contextMenu {
            if isLocked {
                Button("Unlock canonical look") { setLock(nil) }
            } else {
                Button("Lock as canonical look") { setLock(assetId) }
            }
            Button("Show in Media") { revealInMediaTab(assetId) }
        }
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

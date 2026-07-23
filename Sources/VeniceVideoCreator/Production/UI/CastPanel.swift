import AppKit
import SwiftUI

/// Left-dock tab for the production's cast: every character in the shot plan
/// with its reference images and a [re]generate action. References click
/// through to the Media tab.
struct CastPanel: View {
    @Environment(EditorViewModel.self) private var editor

    private var characters: [CharacterSpec] { editor.shotPlan?.characters ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(AppTheme.Border.subtleColor)
            if characters.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(characters) { character in
                            CastRow(
                                character: character,
                                isSelected: editor.selectedCharacterId == character.id,
                                onSelect: { editor.selectCharacter(id: character.id) }
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
            Text("Cast & Objects")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: 0)
            if !characters.isEmpty {
                Text("\(characters.count)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("No cast or objects yet.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text("Ask the agent to create characters or recurring objects/props for your production. Their reference images (and locked voices, for people) appear here.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
    }
}

// MARK: - Cast row

private struct CastRow: View {
    @Environment(EditorViewModel.self) private var editor
    let character: CharacterSpec
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var confirmingRegenerate = false

    private var hasReferences: Bool { !character.referenceImageAssetIds.isEmpty }

    private var anyInFlight: Bool {
        character.referenceImageAssetIds.contains { id in
            guard let a = editor.mediaAssets.first(where: { $0.id == id }) else { return false }
            switch a.generationStatus {
            case .preparing, .generating, .downloading, .rendering: return true
            case .none, .failed, .cancelled: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: character.isObject ? "shippingbox" : "person.crop.square")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .help(character.isObject ? "Object / prop" : "Character")
                Text(character.name.isEmpty ? "Unnamed" : character.name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                if character.voiceReferenceAssetId != nil {
                    Image(systemName: "waveform.badge.checkmark")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .help("Voice reference locked — attached to this character's shots")
                } else if character.lockedVoiceId != nil {
                    Image(systemName: "waveform")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .help("Voice locked")
                }
                Spacer(minLength: 0)
                regenerateButton
            }
            if let description = character.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(2)
            }
            if hasReferences {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(character.referenceImageAssetIds, id: \.self) { aid in
                        referenceThumb(aid)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("No reference images yet.")
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
            "Regenerate reference images for \(character.name.isEmpty ? "this character" : character.name)? This costs credits and replaces the current references on the character (the old images stay in the media library).",
            isPresented: $confirmingRegenerate,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                editor.regenerateCharacterReferences(characterId: character.id)
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
                editor.regenerateCharacterReferences(characterId: character.id)
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
        .help(hasReferences ? "Generate a fresh set of reference images" : "Generate reference images")
    }

    @ViewBuilder
    private func referenceThumb(_ assetId: String) -> some View {
        let isLocked = character.lockedReferenceAssetId == assetId
        let dimmed = character.lockedReferenceAssetId != nil && !isLocked
        Button {
            openInPreview(assetId)
        } label: {
            ReferenceThumbnail(assetId: assetId, maxPixelSize: 160) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs).fill(Color.black)
                    if isInFlight(assetId) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: character.isObject ? "shippingbox" : "person")
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

    private func openInPreview(_ assetId: String) {
        guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else { return }
        editor.openPreviewTab(for: asset)
    }

    private func setLock(_ assetId: String?) {
        guard var updated = editor.character(id: character.id) else { return }
        updated.lockedReferenceAssetId = assetId
        editor.upsertCharacter(updated)
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

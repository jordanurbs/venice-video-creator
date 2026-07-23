import AppKit
import SwiftUI

/// Right-hand inspector for a location selected in the Locations panel.
/// Mirrors CharacterInspector: editable name/description/visual prompt,
/// reference plates with lock, and the shots the location appears in.
struct LocationInspector: View {
    @Environment(EditorViewModel.self) private var editor
    let location: LocationSpec

    @State private var draftName: String = ""
    @State private var draftDescription: String = ""
    @State private var draftPrompt: String = ""
    @State private var confirmingRegenerate = false
    @State private var isEnhancing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                header
                promptSection
                referencesSection
                shotsSection
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncDrafts() }
        .onChange(of: location.id) { _, _ in syncDrafts() }
    }

    private func syncDrafts() {
        draftName = location.name
        draftDescription = location.description ?? ""
        draftPrompt = location.effectiveVisualPrompt
    }

    private func update(_ actionName: String, _ mutate: (inout LocationSpec) -> Void) {
        guard var updated = editor.location(id: location.id) else { return }
        mutate(&updated)
        editor.upsertLocation(updated)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit { commitName() }
            TextField("Description", text: $draftDescription, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1...4)
                .onSubmit { commitDescription() }
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                )
            if draftName != location.name || draftDescription != (location.description ?? "") {
                commitBar(
                    onSave: { commitName(); commitDescription() },
                    onRevert: { draftName = location.name; draftDescription = location.description ?? "" }
                )
            }
        }
    }

    private func commitName() {
        guard draftName != location.name, !draftName.isEmpty else { return }
        update("Rename Location") { $0.name = draftName }
    }

    private func commitDescription() {
        guard draftDescription != (location.description ?? "") else { return }
        update("Edit Location Description") { $0.description = draftDescription.isEmpty ? nil : draftDescription }
    }

    // MARK: - Visual prompt

    private var promptSection: some View {
        inspectorSection("Reference prompt") {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Text("Drives [re]generation of reference plates. The photoreal style suffix and per-plate angles are appended automatically.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                MagicWandButton(isWorking: isEnhancing, isEmpty: draftPrompt.isEmpty) {
                    enhancePrompt()
                }
            }
            TextEditor(text: $draftPrompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 140)
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                )
            if draftPrompt != location.effectiveVisualPrompt {
                commitBar(
                    onSave: { update("Edit Location Prompt") { $0.visualPrompt = draftPrompt } },
                    onRevert: { draftPrompt = location.effectiveVisualPrompt }
                )
            }
        }
    }

    private func enhancePrompt() {
        guard !isEnhancing else { return }
        isEnhancing = true
        let target = location
        let current = draftPrompt
        Task { @MainActor in
            defer { isEnhancing = false }
            guard let enhanced = await PromptEnhancer.enhance(.location(target), current: current, editor: editor) else {
                editor.editorToast = MediaPanelToast(message: "Couldn't enhance the prompt. Check your Venice API key and try again.")
                return
            }
            if editor.selectedLocationId == target.id, draftPrompt == current {
                draftPrompt = enhanced
            }
        }
    }

    private func commitBar(onSave: @escaping () -> Void, onRevert: @escaping () -> Void) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button("Save", action: onSave)
                .buttonStyle(.capsule(.prominent))
                .controlSize(.small)
            Button("Revert", action: onRevert)
                .buttonStyle(.capsule(.secondary))
                .controlSize(.small)
            Spacer(minLength: 0)
        }
    }

    func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                content()
            }
        }
    }
}

// MARK: - References + shots

extension LocationInspector {

    private var anyInFlight: Bool {
        location.referenceImageAssetIds.contains { id in
            guard let a = editor.mediaAssets.first(where: { $0.id == id }) else { return false }
            switch a.generationStatus {
            case .preparing, .generating, .downloading, .rendering: return true
            case .none, .failed, .cancelled: return false
            }
        }
    }

    var referencesSection: some View {
        inspectorSection("Reference plates") {
            if location.referenceImageAssetIds.isEmpty {
                Text("No reference plates yet.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                if location.referenceImageAssetIds.count > 1 {
                    Text(location.lockedReferenceAssetId == nil
                        ? "Generation uses ALL references — if the plates show different environments, lock the best one."
                        : "Locked — generation uses only this reference.")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(location.lockedReferenceAssetId == nil ? AppTheme.Status.warningColor : AppTheme.Text.mutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let columns = [GridItem(.adaptive(minimum: 84), spacing: AppTheme.Spacing.xs)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(location.referenceImageAssetIds, id: \.self) { aid in
                        referenceCell(aid)
                    }
                }
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    if location.referenceImageAssetIds.isEmpty {
                        editor.regenerateLocationReferences(locationId: location.id)
                    } else {
                        confirmingRegenerate = true
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        if anyInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: location.referenceImageAssetIds.isEmpty ? "sparkles" : "arrow.clockwise")
                                .font(.system(size: AppTheme.FontSize.xxs))
                        }
                        Text(location.referenceImageAssetIds.isEmpty ? "Generate" : "Regenerate")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    }
                }
                .buttonStyle(.capsule(.prominent))
                .controlSize(.small)
                .disabled(anyInFlight)
                Spacer(minLength: 0)
            }
            .confirmationDialog(
                "Regenerate reference plates? This costs credits and replaces the current references (old images stay in the media library).",
                isPresented: $confirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button("Regenerate", role: .destructive) {
                    editor.regenerateLocationReferences(locationId: location.id)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func referenceCell(_ assetId: String) -> some View {
        let isLocked = location.lockedReferenceAssetId == assetId
        let dimmed = location.lockedReferenceAssetId != nil && !isLocked
        VStack(spacing: AppTheme.Spacing.xxs) {
            Button {
                guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else { return }
                editor.openPreviewTab(for: asset)
            } label: {
                ReferenceThumbnail(assetId: assetId, maxPixelSize: 220) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black)
                        if let asset = editor.mediaAssets.first(where: { $0.id == assetId }),
                           asset.isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .opacity(dimmed ? AppTheme.Opacity.medium : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            isLocked ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : Color.clear,
                            lineWidth: AppTheme.BorderWidth.medium
                        )
                )
            }
            .buttonStyle(.plain)
            .help("Click to preview")
            .contextMenu {
                Button("Show in Media") {
                    guard editor.mediaAssets.contains(where: { $0.id == assetId }) else { return }
                    editor.selectedMediaAssetIds = [assetId]
                    editor.showMediaPanelMediaTab()
                    editor.mediaPanelRevealAssetId = assetId
                }
            }

            Button {
                update(isLocked ? "Unlock Reference" : "Lock Reference") {
                    $0.lockedReferenceAssetId = isLocked ? nil : assetId
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: AppTheme.FontSize.micro))
                    Text(isLocked ? "Locked" : "Lock")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                }
                .foregroundStyle(isLocked ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
            .help(isLocked ? "Unlock — generation will use all references again" : "Lock this as the location's one canonical look")
        }
    }

    /// Shots set in this location — tap to jump to that shot's inspector.
    var shotsSection: some View {
        inspectorSection("Appears in") {
            let shots = (editor.shotPlan?.shots ?? []).filter { $0.locationIds.contains(location.id) }
            if shots.isEmpty {
                Text("Not attached to any shots.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                ForEach(shots) { shot in
                    Button {
                        editor.selectShot(id: shot.id)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text(shot.slug ?? String(shot.id.prefix(6)))
                                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            Text(shot.summary)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: AppTheme.FontSize.micro))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

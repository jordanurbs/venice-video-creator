import AppKit
import SwiftUI

/// Right-hand inspector for a character selected in the Cast panel. Name,
/// description, and the styled visual prompt driving reference generation are
/// editable (undoable via upsertCharacter); references and voice are shown
/// with their states.
struct CharacterInspector: View {
    @Environment(EditorViewModel.self) private var editor
    let character: CharacterSpec

    @State private var draftName: String = ""
    @State private var draftDescription: String = ""
    @State private var draftPrompt: String = ""
    @State private var confirmingRegenerate = false
    @State private var isEnhancing = false
    /// Voice id picked in the audition picker (not yet locked).
    @State private var auditionVoice: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                header
                promptSection
                referencesSection
                if !character.isObject {
                    voiceSection
                }
                shotsSection
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncDrafts() }
        .onChange(of: character.id) { _, _ in
            syncDrafts()
            InspectorAudioPlayer.shared.stop()
        }
        .onDisappear { InspectorAudioPlayer.shared.stop() }
    }

    private func syncDrafts() {
        draftName = character.name
        draftDescription = character.description ?? ""
        draftPrompt = character.effectiveVisualPrompt
    }

    private func update(_ actionName: String, _ mutate: (inout CharacterSpec) -> Void) {
        guard var updated = editor.character(id: character.id) else { return }
        mutate(&updated)
        editor.upsertCharacter(updated)
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
            if draftName != character.name || draftDescription != (character.description ?? "") {
                commitBar(
                    onSave: { commitName(); commitDescription() },
                    onRevert: { draftName = character.name; draftDescription = character.description ?? "" }
                )
            }
        }
    }

    private func commitName() {
        guard draftName != character.name, !draftName.isEmpty else { return }
        update("Rename Character") { $0.name = draftName }
    }

    private func commitDescription() {
        guard draftDescription != (character.description ?? "") else { return }
        update("Edit Character Description") { $0.description = draftDescription.isEmpty ? nil : draftDescription }
    }

    // MARK: - Visual prompt

    private var promptSection: some View {
        inspectorSection("Reference prompt") {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Text("Drives [re]generation of reference images. The photoreal style suffix and per-pose framing are appended automatically.")
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
            if draftPrompt != character.effectiveVisualPrompt {
                commitBar(
                    onSave: { update("Edit Character Prompt") { $0.visualPrompt = draftPrompt } },
                    onRevert: { draftPrompt = character.effectiveVisualPrompt }
                )
            }
        }
    }

    private func enhancePrompt() {
        guard !isEnhancing else { return }
        isEnhancing = true
        let target = character
        let current = draftPrompt
        Task { @MainActor in
            defer { isEnhancing = false }
            guard let enhanced = await PromptEnhancer.enhance(.character(target), current: current, editor: editor) else {
                editor.editorToast = MediaPanelToast(message: "Couldn't enhance the prompt. Check your Venice API key and try again.")
                return
            }
            if editor.selectedCharacterId == target.id, draftPrompt == current {
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

// MARK: - References, voice, shots

extension CharacterInspector {

    private var anyInFlight: Bool {
        character.referenceImageAssetIds.contains { id in
            guard let a = editor.mediaAssets.first(where: { $0.id == id }) else { return false }
            switch a.generationStatus {
            case .preparing, .generating, .downloading, .rendering: return true
            case .none, .failed, .cancelled: return false
            }
        }
    }

    /// Only ids that resolve to a live asset — ghost ids (asset deleted
    /// out-of-band) must not render as permanent blank tiles.
    private var resolvedReferenceIds: [String] {
        character.referenceImageAssetIds.filter { editor.mediaAssetsById[$0] != nil }
    }

    var referencesSection: some View {
        inspectorSection("Reference images") {
            if resolvedReferenceIds.isEmpty {
                Text("No reference images yet.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                if resolvedReferenceIds.count > 1 {
                    Text(character.lockedReferenceAssetId == nil
                        ? "Generation uses ALL references — if the takes look different, lock the best one so models aren't fed divergent looks."
                        : "Locked — generation uses only this reference.")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(character.lockedReferenceAssetId == nil ? AppTheme.Status.warningColor : AppTheme.Text.mutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let columns = [GridItem(.adaptive(minimum: 84), spacing: AppTheme.Spacing.xs)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(resolvedReferenceIds, id: \.self) { aid in
                        referenceCell(aid)
                    }
                }
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    if character.referenceImageAssetIds.isEmpty {
                        editor.regenerateCharacterReferences(characterId: character.id)
                    } else {
                        confirmingRegenerate = true
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        if anyInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: character.referenceImageAssetIds.isEmpty ? "sparkles" : "arrow.clockwise")
                                .font(.system(size: AppTheme.FontSize.xxs))
                        }
                        Text(character.referenceImageAssetIds.isEmpty ? "Generate" : "Regenerate")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    }
                }
                .buttonStyle(.capsule(.prominent))
                .controlSize(.small)
                .disabled(anyInFlight)
                // Attach an existing library image as a reference — recovers a
                // detached ref (or reuses any generated portrait) without
                // regenerating from scratch.
                libraryPickerMenu
                Spacer(minLength: 0)
            }
            .confirmationDialog(
                "Regenerate reference images? This costs credits and replaces the current references (old images stay in the media library).",
                isPresented: $confirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button("Regenerate", role: .destructive) {
                    editor.regenerateCharacterReferences(characterId: character.id)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func referenceCell(_ assetId: String) -> some View {
        let isLocked = character.lockedReferenceAssetId == assetId
        let dimmed = character.lockedReferenceAssetId != nil && !isLocked
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
                            Image(systemName: character.isObject ? "shippingbox" : "person")
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
            .help(isLocked ? "Unlock — generation will use all references again" : "Lock this as the character's one canonical look")
        }
    }

    /// Menu of library images not already attached — shared picker, so the
    /// user can populate references without relying on the agent.
    private var libraryPickerMenu: some View {
        LibraryReferencePicker(excludedAssetIds: Set(character.referenceImageAssetIds)) { asset in
            update("Attach Reference") { c in
                if !c.referenceImageAssetIds.contains(asset.id) {
                    c.referenceImageAssetIds.append(asset.id)
                }
                if c.lockedReferenceAssetId == nil {
                    c.lockedReferenceAssetId = asset.id
                }
            }
        }
    }

    private var anyVoiceSampleInFlight: Bool {
        character.voiceSampleAssetIds.contains { id in
            guard let a = editor.mediaAssets.first(where: { $0.id == id }) else { return false }
            switch a.generationStatus {
            case .preparing, .generating, .downloading, .rendering: return true
            case .none, .failed, .cancelled: return false
            }
        }
    }

    /// The TTS model whose voices the picker offers: the character's locked
    /// model when set and enabled, else the first enabled TTS model with voices.
    private var voicePickerModel: AudioModelConfig? {
        character.voiceModel
            .flatMap { vm in AudioModelConfig.allModels.first { $0.id == vm && ModelPreferences.shared.isEnabled($0.id) } }
            ?? AudioModelConfig.allModels.first {
                $0.category == .tts && $0.voices?.isEmpty == false && ModelPreferences.shared.isEnabled($0.id)
            }
    }

    var voiceSection: some View {
        inspectorSection("Voice") {
            if let voice = character.lockedVoiceId {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "waveform")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(voice)
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if let model = character.voiceModel {
                        Text(model)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    Spacer(minLength: 0)
                    Button("Unlock") {
                        update("Unlock Voice") { $0.lockedVoiceId = nil }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .help("Clear the locked voice to audition a different one")
                }
            } else {
                Text("No voice locked. Pick a voice below and audition it — new samples are generated in the selected voice.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Voice picker + audition: browse the TTS model's voices, generate
            // a sample in a chosen voice, then lock the winner from its row.
            if let model = voicePickerModel, let voices = model.voices, !voices.isEmpty {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Picker("Voice", selection: $auditionVoice) {
                        Text("Choose a voice…").tag("")
                        ForEach(voices, id: \.self) { v in
                            Text(v).tag(v)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 180, alignment: .leading)
                    Button {
                        editor.generateCharacterVoiceSample(
                            characterId: character.id,
                            voice: auditionVoice.isEmpty ? nil : auditionVoice,
                            lockIfUnset: false
                        )
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xxs) {
                            Image(systemName: "waveform.badge.plus")
                                .font(.system(size: AppTheme.FontSize.xxs))
                            Text("Audition")
                                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        }
                    }
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
                    .disabled(auditionVoice.isEmpty || anyVoiceSampleInFlight)
                    .help(auditionVoice.isEmpty
                        ? "Pick a voice to audition"
                        : "Generate a spoken sample in '\(auditionVoice)' (\(model.displayName))")
                    Spacer(minLength: 0)
                }
            }

            if !character.voiceSampleAssetIds.isEmpty {
                Text(character.voiceReferenceAssetId == nil
                    ? "Lock a sample to attach it as this character's voice reference during shot generation."
                    : "Locked — shots with this character attach this audio as the voice reference by default.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(character.voiceReferenceAssetId == nil ? AppTheme.Status.warningColor : AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(character.voiceSampleAssetIds, id: \.self) { aid in
                    voiceSampleRow(aid)
                }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    editor.generateCharacterVoiceSample(characterId: character.id)
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        if anyVoiceSampleInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: character.voiceSampleAssetIds.isEmpty ? "sparkles" : "arrow.clockwise")
                                .font(.system(size: AppTheme.FontSize.xxs))
                        }
                        Text(character.voiceSampleAssetIds.isEmpty ? "Generate voice sample" : "New sample")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    }
                }
                .buttonStyle(.capsule(.prominent))
                .controlSize(.small)
                .disabled(anyVoiceSampleInFlight)
                .help("Generate a spoken sample in the character's voice (uses the locked voice, or the default TTS voice)")
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func voiceSampleRow(_ assetId: String) -> some View {
        let isLocked = character.voiceReferenceAssetId == assetId
        let asset = editor.mediaAssets.first(where: { $0.id == assetId })
        let isPlayable = asset != nil && asset?.isGenerating != true
            && FileManager.default.fileExists(atPath: asset?.url.path ?? "")
        let isPlaying = InspectorAudioPlayer.shared.isPlaying(assetId)
        let sampleVoice = asset?.generationInput?.voice
        let isLockedVoice = sampleVoice != nil && sampleVoice == character.lockedVoiceId
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                guard let asset, isPlayable else { return }
                InspectorAudioPlayer.shared.toggle(assetId: assetId, url: asset.url)
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    if let asset, asset.isGenerating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(isPlaying ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                    }
                    Text(asset?.name ?? String(assetId.prefix(8)))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(asset == nil ? AppTheme.Status.errorColor : AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Accent.primary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isPlayable)
            .help(isPlayable ? (isPlaying ? "Stop" : "Play sample") : "Sample not ready yet")
            Spacer(minLength: 0)
            // Lock the sample's VOICE as the character's voice (dialogue TTS).
            // Distinct from the reference lock on the right, which pins this
            // audio file as the shot-generation voice reference.
            if let sampleVoice, !isLockedVoice {
                Button("Use voice") {
                    update("Lock Voice") { c in
                        c.lockedVoiceId = sampleVoice
                        if c.voiceModel == nil { c.voiceModel = asset?.generationInput?.model }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .disabled(asset?.isGenerating == true)
                .help("Lock '\(sampleVoice)' as \(character.name.isEmpty ? "this character" : character.name)'s voice for dialogue")
            } else if isLockedVoice {
                Text(sampleVoice ?? "")
                    .font(.system(size: AppTheme.FontSize.xxs, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .help("This sample's voice is the locked voice")
            }
            Button {
                update(isLocked ? "Unlock Voice Reference" : "Lock Voice Reference") {
                    $0.voiceReferenceAssetId = isLocked ? nil : assetId
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
            .disabled(asset == nil || asset?.isGenerating == true)
            .help(isLocked ? "Unlock — shots stop attaching this audio automatically" : "Lock as the character's voice reference for shot generation")
        }
    }

    /// Shots this character appears in — tap to jump to that shot's inspector.
    var shotsSection: some View {
        inspectorSection("Appears in") {
            let shots = (editor.shotPlan?.shots ?? []).filter { $0.characterIds.contains(character.id) }
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

import AppKit
import SwiftUI

/// Right-hand inspector for a shot selected in the Production panel. Every field
/// is pre-filled from the agent's plan and editable; edits persist through
/// `upsertShot` (undoable). Values inherited from plan defaults are labeled so
/// the user can tell the assistant's choices from their own overrides.
struct ShotInspector: View {
    @Environment(EditorViewModel.self) private var editor
    let shot: Shot

    @State private var draftSummary: String = ""
    @State private var draftPrompt: String = ""
    @State private var isEnhancing = false

    private var plan: ShotPlan? { editor.shotPlan }
    private var shotIndex: Int {
        plan?.shots.firstIndex(where: { $0.id == shot.id }) ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                header
                promptSection
                generationSection
                referencesSection
                audioSection
                outputSection
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { syncDrafts() }
        .onChange(of: shot.id) { _, _ in syncDrafts() }
    }

    private func syncDrafts() {
        draftSummary = shot.summary
        draftPrompt = shot.prompt
    }

    // MARK: - Mutation

    private func update(_ actionName: String, _ mutate: (inout Shot) -> Void) {
        guard var updated = editor.shot(id: shot.id) else { return }
        mutate(&updated)
        editor.mutateShotPlan(actionName: actionName) { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shot.id }) else { return }
            plan.shots[idx] = updated
        }
    }

    /// Editing creative fields on a generated shot marks it stale (back to
    /// storyboarded/planned) so Regenerate is offered — never auto-regenerates.
    private func markStaleIfGenerated(_ shot: inout Shot) {
        switch shot.status {
        case .qa, .approved, .placed:
            shot.status = shot.storyboardAssetId != nil ? .storyboarded : .planned
        default:
            break
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(shot.slug ?? "S\(shotIndex + 1)")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                statusBadge
                Spacer(minLength: 0)
            }
            TextField("Summary", text: $draftSummary, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1...3)
                .onSubmit { commitSummary() }
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                )
            if draftSummary != shot.summary {
                commitBar(
                    onSave: { commitSummary() },
                    onRevert: { draftSummary = shot.summary }
                )
            }
        }
    }

    private func commitSummary() {
        guard draftSummary != shot.summary else { return }
        update("Edit Shot Summary") { $0.summary = draftSummary }
    }

    private var statusBadge: some View {
        Text(shot.status.rawValue)
            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(statusColor.opacity(AppTheme.Opacity.faint)))
    }

    private var statusColor: Color {
        switch shot.status {
        case .planned, .storyboarded: return AppTheme.Text.tertiaryColor
        case .generating, .qa: return AppTheme.Status.warningColor
        case .approved, .placed: return AppTheme.Status.successColor
        case .failed: return AppTheme.Status.errorColor
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        section("Prompt") {
            HStack(spacing: AppTheme.Spacing.sm) {
                Spacer(minLength: 0)
                MagicWandButton(isWorking: isEnhancing, isEmpty: draftPrompt.isEmpty) {
                    enhancePrompt()
                }
            }
            TextEditor(text: $draftPrompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 180)
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                )
            if draftPrompt != shot.prompt {
                commitBar(
                    onSave: {
                        update("Edit Shot Prompt") {
                            $0.prompt = draftPrompt
                            markStaleIfGenerated(&$0)
                        }
                    },
                    onRevert: { draftPrompt = shot.prompt }
                )
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

    /// Writes/enhances the prompt draft from project context. Result lands in
    /// the draft only — the user reviews and saves (or reverts) explicitly.
    private func enhancePrompt() {
        guard !isEnhancing else { return }
        isEnhancing = true
        let target = shot
        let current = draftPrompt
        Task { @MainActor in
            defer { isEnhancing = false }
            guard let enhanced = await PromptEnhancer.enhance(.shot(target), current: current, editor: editor) else {
                editor.editorToast = MediaPanelToast(message: "Couldn't enhance the prompt. Check your Venice API key and try again.")
                return
            }
            // Only apply if the shot is still selected and the draft untouched.
            if editor.selectedShotId == target.id, draftPrompt == current {
                draftPrompt = enhanced
            }
        }
    }
}

/// Shared wand affordance for prompt fields: sparkles when the field is empty
/// ("write it for me"), wand when it has content ("improve it").
struct MagicWandButton: View {
    let isWorking: Bool
    let isEmpty: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                if isWorking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isEmpty ? "sparkles" : "wand.and.stars")
                        .font(.system(size: AppTheme.FontSize.xxs))
                }
                Text(isEmpty ? "Write" : "Enhance")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
            }
            .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .help(isEmpty ? "Write a prompt from the project's script and style" : "Enhance this prompt using project context")
    }
}

// MARK: - Generation, references, audio, output sections

extension ShotInspector {

    private var planDefaultSeconds: Double { editor.shotPlan?.defaultShotSeconds ?? 5 }
    private var planDefaultModelId: String? { editor.shotPlan?.defaultModel }

    private var enabledVideoModels: [VideoModelConfig] {
        VideoModelConfig.allModels.filter { ModelPreferences.shared.isEnabled($0.id) }
    }

    private func modelDisplayName(_ id: String?) -> String {
        guard let id else { return "None" }
        return VideoModelConfig.allModels.first(where: { $0.id == id })?.displayName ?? id
    }

    /// The model production will actually use for this shot (override, else plan
    /// default, else first enabled) — its caps drive the duration/resolution UI.
    private var effectiveModel: VideoModelConfig? {
        let id = shot.modelOverride ?? planDefaultModelId
        return id.flatMap { mid in enabledVideoModels.first { $0.id == mid } }
            ?? enabledVideoModels.first
    }

    var generationSection: some View {
        section("Generation") {
            labeledRow("Duration") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    durationControl
                    if shot.durationSeconds == planDefaultSeconds {
                        inheritedTag("plan default")
                    }
                }
            }
            overlongWarning
            labeledRow("Model") {
                Menu {
                    Button {
                        update("Edit Shot Model") { s in
                            s.modelOverride = nil
                            markStaleIfGenerated(&s)
                        }
                    } label: {
                        HStack {
                            Text("Default (\(modelDisplayName(planDefaultModelId)))")
                            if shot.modelOverride == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(enabledVideoModels, id: \.id) { m in
                        Button {
                            update("Edit Shot Model") { s in
                                s.modelOverride = m.id
                                markStaleIfGenerated(&s)
                            }
                        } label: {
                            HStack {
                                Text(m.displayName)
                                if shot.modelOverride == m.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text(shot.modelOverride.map { modelDisplayName($0) } ?? "Default (\(modelDisplayName(planDefaultModelId)))")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(shot.modelOverride == nil ? AppTheme.Text.tertiaryColor : AppTheme.Text.secondaryColor)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            labeledRow("Motion") {
                picker(ShotMotionLevel.allCases, selected: shot.motionLevel, label: { $0.rawValue }) { level in
                    update("Edit Shot Motion") { s in
                        s.motionLevel = level
                        markStaleIfGenerated(&s)
                    }
                }
            }
            labeledRow("Transition") {
                picker(ShotTransition.allCases, selected: shot.transition, label: { $0.rawValue }) { t in
                    update("Edit Shot Transition") { s in s.transition = t }
                }
            }
            if let plan = editor.shotPlan {
                labeledRow("Aspect") {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(plan.aspectRatio)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        inheritedTag("plan-wide")
                    }
                }
                labeledRow("Resolution") {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        resolutionControl(plan)
                        inheritedTag("plan-wide")
                    }
                }
            }
        }
    }

    /// Overlong shots (from plans saved before the cap, or free-stepper edits)
    /// can't be generated in one clip — offer a one-click split into chained parts.
    @ViewBuilder
    private var overlongWarning: some View {
        let cap = ToolExecutor.maxGenerableShotSeconds()
        if shot.durationSeconds > cap {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("\(Int(shot.durationSeconds))s exceeds the longest generable clip (\(Int(cap))s). Production would truncate this shot.")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let parts = editor.splitShot(id: shot.id, cap: cap), let first = parts.first {
                        editor.selectShot(id: first.id)
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: "scissors")
                            .font(.system(size: AppTheme.FontSize.xxs))
                        Text("Split into \(Int(ceil(shot.durationSeconds / cap))) chained shots")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    }
                }
                .buttonStyle(.capsule(.prominent))
                .controlSize(.small)
            }
        }
    }

    /// Duration snaps to the effective model's supported ladder (e.g. Seedance
    /// 5s/10s/15s). Free stepper only when the model has no declared ladder.
    @ViewBuilder
    private var durationControl: some View {
        let current = Int(shot.durationSeconds.rounded())
        if let model = effectiveModel, !model.durations.isEmpty {
            picker(model.durations.sorted(), selected: nearestDuration(current, in: model.durations), label: { "\($0)s" }) { d in
                update("Edit Shot Duration") { s in
                    s.durationSeconds = Double(d)
                    markStaleIfGenerated(&s)
                }
            }
        } else {
            Stepper(
                value: Binding(
                    get: { editor.shot(id: shot.id)?.durationSeconds ?? shot.durationSeconds },
                    set: { v in update("Edit Shot Duration") { s in
                        s.durationSeconds = max(1, v)
                        markStaleIfGenerated(&s)
                    } }
                ),
                in: 1...60, step: 1
            ) {
                Text("\(current)s")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .controlSize(.small)
        }
    }

    private func nearestDuration(_ requested: Int, in ladder: [Int]) -> Int {
        ladder.min { abs($0 - requested) < abs($1 - requested) } ?? requested
    }

    /// Resolution is a plan-wide setting; offer the effective model's options
    /// (e.g. Seedance 480p/720p/1080p/4K) and persist to the plan.
    @ViewBuilder
    private func resolutionControl(_ plan: ShotPlan) -> some View {
        if let model = effectiveModel, let allowed = model.resolutions, !allowed.isEmpty {
            let current = allowed.contains(plan.resolution) ? plan.resolution : (allowed.first ?? plan.resolution)
            picker(allowed, selected: current, label: { $0 }) { r in
                editor.mutateShotPlan(actionName: "Edit Plan Resolution") { p in
                    p.resolution = r
                }
            }
        } else {
            Text(plan.resolution)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }
}

extension ShotInspector {

    var referencesSection: some View {
        section("References") {
            if shot.characterIds.isEmpty && shot.locationIds.isEmpty {
                Text("No characters or locations attached.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            if !shot.characterIds.isEmpty {
                ForEach(shot.characterIds, id: \.self) { cid in
                    characterRow(cid)
                }
            }
            if !shot.locationIds.isEmpty {
                ForEach(shot.locationIds, id: \.self) { lid in
                    locationRow(lid)
                }
            }
            HStack(spacing: AppTheme.Spacing.md) {
                attachCharacterMenu
                attachLocationMenu
            }
        }
    }

    private func locationRow(_ locationId: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let location = editor.location(id: locationId) {
                locationReferenceThumbs(location)
                Text(location.name.isEmpty ? "Unnamed" : location.name)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                Image(systemName: "map")
                    .font(.system(size: AppTheme.FontSize.micro))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            } else {
                Text("Missing location (\(String(locationId.prefix(6))))")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
            Spacer(minLength: 0)
            Button {
                update("Detach Location") { s in
                    s.locationIds.removeAll { $0 == locationId }
                    markStaleIfGenerated(&s)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .buttonStyle(.plain)
            .help("Detach from this shot")
        }
    }

    private func locationReferenceThumbs(_ location: LocationSpec) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ForEach(location.activeReferenceAssetIds.prefix(3), id: \.self) { aid in
                ReferenceThumbnail(assetId: aid, maxPixelSize: 96) {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        )
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            }
        }
    }

    @ViewBuilder
    private var attachLocationMenu: some View {
        let unattached = (editor.shotPlan?.locations ?? []).filter { !shot.locationIds.contains($0.id) }
        if !unattached.isEmpty {
            Menu {
                ForEach(unattached, id: \.id) { l in
                    Button {
                        update("Attach Location") { s in
                            s.locationIds.append(l.id)
                            markStaleIfGenerated(&s)
                        }
                    } label: {
                        Label(l.name.isEmpty ? "Unnamed" : l.name, systemImage: "map")
                    }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.xxs))
                    Text("Attach location")
                        .font(.system(size: AppTheme.FontSize.xs))
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func characterRow(_ characterId: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let character = editor.character(id: characterId) {
                referenceThumbs(character)
                Text(character.name.isEmpty ? "Unnamed" : character.name)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            } else {
                Text("Missing character (\(String(characterId.prefix(6))))")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
            Spacer(minLength: 0)
            Button {
                update("Detach Character") { s in
                    s.characterIds.removeAll { $0 == characterId }
                    markStaleIfGenerated(&s)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .buttonStyle(.plain)
            .help("Detach from this shot")
        }
    }

    private func referenceThumbs(_ character: CharacterSpec) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            ForEach(character.activeReferenceAssetIds.prefix(3), id: \.self) { aid in
                ReferenceThumbnail(assetId: aid, maxPixelSize: 96) {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                        .overlay(
                            Image(systemName: character.isObject ? "shippingbox" : "person")
                                .font(.system(size: AppTheme.FontSize.xxs))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                        )
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            }
        }
    }

    @ViewBuilder
    private var attachCharacterMenu: some View {
        let unattached = (editor.shotPlan?.characters ?? []).filter { !shot.characterIds.contains($0.id) }
        if !unattached.isEmpty {
            Menu {
                ForEach(unattached, id: \.id) { c in
                    Button {
                        update("Attach Character") { s in
                            s.characterIds.append(c.id)
                            markStaleIfGenerated(&s)
                        }
                    } label: {
                        if let face = CharacterThumbs.face(for: c, editor: editor) {
                            Label {
                                Text(c.name.isEmpty ? "Unnamed" : c.name)
                            } icon: {
                                Image(nsImage: face)
                            }
                        } else {
                            Label(c.name.isEmpty ? "Unnamed" : c.name, systemImage: "person")
                        }
                    }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.xxs))
                    Text("Attach character")
                        .font(.system(size: AppTheme.FontSize.xs))
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

extension ShotInspector {

    var audioSection: some View {
        section("Audio") {
            Text("Audio is always generated — mix it down here or in the timeline.")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .fixedSize(horizontal: false, vertical: true)
            labeledRow("Content") {
                picker(ShotAudioContent.allCases, selected: shot.audioContent, label: { $0.label }) { v in
                    update("Edit Shot Audio Content") { s in
                        s.audioContent = v
                        markStaleIfGenerated(&s)
                    }
                }
            }
            labeledRow("Mix on placement") {
                picker(ShotNativeAudio.allCases, selected: shot.nativeAudio, label: { $0.rawValue }) { v in
                    update("Edit Shot Audio") { s in s.nativeAudio = v }
                }
            }
            audioReferenceRows
            if !shot.dialogue.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(shot.dialogue) { line in
                        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                            Text(line.voiceOver ? "VO" : "DLG")
                                .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                                .foregroundStyle(line.voiceOver ? AppTheme.Status.warningColor : AppTheme.Text.tertiaryColor)
                            Text(speakerLabel(line) + line.text)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Audio reference controls: an explicit attachment (wins) or the default
    /// cast-voice toggle. Only offered on models that accept audio input.
    @ViewBuilder
    private var audioReferenceRows: some View {
        let modelSupportsAudio = (effectiveModel?.maxReferenceAudios ?? 0) > 0
        let castVoiceRef = defaultCastVoiceReference

        if let explicitId = shot.audioReferenceAssetId {
            labeledRow("Audio reference") {
                HStack(spacing: AppTheme.Spacing.xs) {
                    audioRefLabel(assetId: explicitId)
                    Button {
                        update("Detach Audio Reference") { s in
                            s.audioReferenceAssetId = nil
                            markStaleIfGenerated(&s)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .buttonStyle(.plain)
                    .help("Detach — the cast voice reference (if any) applies again")
                }
            }
        } else {
            labeledRow("Audio reference") { attachAudioReferenceMenu }
            if let (character, refId) = castVoiceRef {
                labeledRow("Cast voice") {
                    Toggle(isOn: Binding(
                        get: { editor.shot(id: shot.id)?.attachCastVoiceReference ?? shot.attachCastVoiceReference },
                        set: { on in update("Toggle Cast Voice Reference") { s in
                            s.attachCastVoiceReference = on
                            markStaleIfGenerated(&s)
                        } }
                    )) {
                        Text("\(character.name.isEmpty ? "Unnamed" : character.name)'s voice")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Attach the character's locked voice reference as audio_url when the model supports audio input")
                }
                if shot.attachCastVoiceReference {
                    audioRefHint(assetId: refId, supported: modelSupportsAudio)
                }
            }
        }
        if shot.audioReferenceAssetId != nil {
            audioRefHint(assetId: shot.audioReferenceAssetId, supported: modelSupportsAudio)
        }
    }

    /// The character + voice-reference asset that would be auto-attached.
    private var defaultCastVoiceReference: (CharacterSpec, String)? {
        for cid in shot.characterIds {
            if let c = editor.character(id: cid), let refId = c.voiceReferenceAssetId {
                return (c, refId)
            }
        }
        return nil
    }

    @ViewBuilder
    private func audioRefHint(assetId: String?, supported: Bool) -> some View {
        if assetId != nil, !supported {
            Text("The effective model doesn't accept audio input — the reference is skipped. Pick an audio-input model (Seedance R2V, Wan 2.5/2.6/2.7) to use it.")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func audioRefLabel(assetId: String) -> some View {
        let asset = editor.mediaAssets.first(where: { $0.id == assetId })
        return HStack(spacing: AppTheme.Spacing.xxs) {
            Image(systemName: "waveform")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(asset?.name ?? String(assetId.prefix(8)))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(asset == nil ? AppTheme.Status.errorColor : AppTheme.Text.secondaryColor)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var attachAudioReferenceMenu: some View {
        let audioAssets = editor.mediaAssets.filter { $0.type == .audio && !$0.isGenerating }
        if audioAssets.isEmpty {
            Text("None")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        } else {
            Menu {
                ForEach(audioAssets, id: \.id) { a in
                    Button {
                        update("Attach Audio Reference") { s in
                            s.audioReferenceAssetId = a.id
                            markStaleIfGenerated(&s)
                        }
                    } label: {
                        Label(a.name, systemImage: "waveform")
                    }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.xxs))
                    Text("Attach audio")
                        .font(.system(size: AppTheme.FontSize.xs))
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func speakerLabel(_ line: ShotDialogue) -> String {
        if let cid = line.characterId, let c = editor.character(id: cid), !c.name.isEmpty {
            return c.name + ": "
        }
        if let s = line.speaker, !s.isEmpty { return s + ": " }
        return ""
    }

    var outputSection: some View {
        section("Output") {
            if let panelId = shot.storyboardAssetId {
                outputThumb(assetId: panelId, label: "Storyboard")
            }
            if let videoId = shot.videoAssetId {
                outputThumb(assetId: videoId, label: "Video (latest take)")
            }
            if let qa = shot.qaSummary, !qa.isEmpty {
                Text(qa)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = shot.failureReason, !failure.isEmpty {
                Text(failure)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shot.takes.count > 1 {
                Text("\(shot.takes.count) takes")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                let orchestrator = editor.productionOrchestrator
                let isGenerating = orchestrator.currentShotId == shot.id
                let isQueued = orchestrator.pendingQueue.contains(shot.id)
                Button {
                    orchestrator.produceShots(ids: [shot.id])
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: isGenerating ? "hourglass" : (isQueued ? "clock" : "arrow.clockwise"))
                            .font(.system(size: AppTheme.FontSize.xxs))
                        Text(isGenerating ? "Generating" : (isQueued ? "Queued" : (shot.videoAssetId == nil ? "Generate" : "Regenerate")))
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    }
                }
                .buttonStyle(.capsule(.prominent))
                .controlSize(.small)
                .disabled(isGenerating || isQueued)
                Spacer(minLength: 0)
            }
        }
    }

    private func outputThumb(assetId: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(Color.black)
                if let asset = editor.mediaAssets.first(where: { $0.id == assetId }) {
                    if let thumb = asset.thumbnail {
                        Image(nsImage: thumb).resizable().scaledToFit()
                    } else if isInFlight(asset) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "film")
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                } else {
                    Text("Asset missing")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
    }

    private func isInFlight(_ asset: MediaAsset) -> Bool {
        switch asset.generationStatus {
        case .preparing, .generating, .downloading, .rendering: return true
        case .none, .failed, .cancelled: return false
        }
    }

    // MARK: - Small shared builders

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

    func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            content()
        }
        .frame(minHeight: AppTheme.IconSize.md)
    }

    func inheritedTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.micro))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(AppTheme.Opacity.subtle)))
    }

    func picker<T: Hashable>(
        _ options: [T], selected: T, label: @escaping (T) -> String, onPick: @escaping (T) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onPick(option)
                } label: {
                    HStack {
                        Text(label(option))
                        if option == selected { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text(label(selected))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

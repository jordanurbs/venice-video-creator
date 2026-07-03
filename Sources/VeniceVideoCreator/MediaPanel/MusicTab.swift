import SwiftUI

struct MusicTab: View {
    @Environment(EditorViewModel.self) var editor
    @Bindable private var account = AccountService.shared

    @State private var selectedModelId: String?
    @State private var mode: MusicGenerationSubmission.Mode = .videoToMusic
    @State private var prompt: String = ""
    @State private var textDuration: Double = 90
    @State private var isGenerating = false
    @State private var generatingLabel = "Generating..."
    @State private var generatingAssetId: String?
    @State private var runTask: Task<Void, Never>?
    @State private var note: String?

    private var models: [AudioModelConfig] {
        AudioModelConfig.allModels.filter { $0.category == .music }
    }

    private var model: AudioModelConfig? {
        if let id = selectedModelId, let m = models.first(where: { $0.id == id }) { return m }
        return models.first
    }

    private func supportsTextMode(_ m: AudioModelConfig) -> Bool { m.inputs.contains(.text) }
    private func supportsVideoMode(_ m: AudioModelConfig) -> Bool { m.inputs.contains(.video) }

    /// Clamp the chosen mode to what the selected model can actually do.
    private var effectiveMode: MusicGenerationSubmission.Mode {
        guard let model else { return mode }
        switch mode {
        case .videoToMusic: return supportsVideoMode(model) ? .videoToMusic : .textToMusic
        case .textToMusic: return supportsTextMode(model) ? .textToMusic : .videoToMusic
        }
    }
    private var isTextMode: Bool { effectiveMode == .textToMusic }

    private var source: EditorViewModel.TimelineSpan? { editor.selectedTimelineSpan() }

    private var spanSeconds: Double {
        guard let source else { return 0 }
        return Double(source.frameCount) / Double(max(1, editor.timeline.fps))
    }

    /// Where a text-to-music clip lands: the marked range start, else the playhead.
    private var textPlacementFrame: Int {
        editor.validSelectedTimelineRange?.startFrame ?? editor.currentFrame
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var costDuration: Int {
        isTextMode ? Int(textDuration.rounded()) : Int(spanSeconds.rounded())
    }

    private var estimatedCost: Int? {
        guard let model, costDuration > 0 else { return nil }
        return CostEstimator.audioCost(model: model, prompt: trimmedPrompt, durationSeconds: costDuration)
    }

    private var validationNote: String? {
        guard let model else {
            return ModelCatalog.shared.isLoaded ? "No music models available." : "Loading models…"
        }
        if isTextMode {
            if trimmedPrompt.isEmpty { return "Describe the music to generate." }
        } else {
            guard source != nil else {
                return "Add video to the timeline, then mark a range to score only part of it."
            }
            if let issue = model.validate(spanSeconds: spanSeconds) { return issue }
        }
        return nil
    }

    private var canGenerate: Bool {
        model != nil && validationNote == nil && !isGenerating
    }

    private var generateLabel: String {
        if let cost = estimatedCost, cost > 0 { return "Generate · \(CostEstimator.format(cost))" }
        return "Generate"
    }

    private var sourceSummary: String {
        guard let source else { return "No video" }
        let scope = editor.validSelectedTimelineRange != nil ? "" : "Whole timeline · "
        return "\(scope)\(clock(source.startFrame)) – \(clock(source.startFrame + source.frameCount)) · \(String(format: "%.1fs", spanSeconds))"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
                        sourceSection
                        modelSection
                        promptSection
                    }
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.md)
                    .padding(.bottom, AppTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                VStack(spacing: AppTheme.Spacing.md) {
                    GeneratingOverlay(label: generatingLabel, size: .preview)
                    Button("Cancel") { cancelGeneration() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }

    /// Show the input toggle only when the selected model can do both modes.
    private var canToggleMode: Bool {
        guard let model else { return false }
        return supportsVideoMode(model) && supportsTextMode(model)
    }

    private var sourceSection: some View {
        InspectorSection("Source") {
            if canToggleMode {
                InspectorRow(icon: "slider.horizontal.3", label: "Input") {
                    Menu {
                        Button("Video to Music") { mode = .videoToMusic }
                        Button("Text to Music") { mode = .textToMusic }
                    } label: { menuValueLabel(modeLabel(effectiveMode)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
                }
            }
            if isTextMode {
                InspectorRow(
                    icon: "clock",
                    label: "Duration",
                    labelHelp: "Length of the generated music. It's placed at the playhead, or at the marked range start."
                ) {
                    ScrubbableNumberField(
                        value: textDuration,
                        range: 1...600,
                        format: "%.0f",
                        valueSuffix: " s",
                        onChanged: { textDuration = $0 }
                    ) { textDuration = $0 }
                }
            } else {
                InspectorRow(
                    icon: "film",
                    label: "Video",
                    labelHelp: "Uses the whole timeline by default. Mark a range on the timeline to score only that span."
                ) { valueText(sourceSummary) }
            }
        }
    }

    private func modeLabel(_ m: MusicGenerationSubmission.Mode) -> String {
        switch m {
        case .videoToMusic: "Video to Music"
        case .textToMusic: "Text to Music"
        }
    }

    private func menuValueLabel(_ text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .lineLimit(1)
    }

    private var modelSection: some View {
        InspectorSection("Model") {
            InspectorRow(icon: "music.note", label: "Model") {
                Menu {
                    ForEach(models, id: \.id) { m in
                        Button(m.displayName) { selectedModelId = m.id }
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text(model?.displayName ?? "None")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: AppTheme.FontSize.xxs))
                    }
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            }
        }
    }

    private var promptSection: some View {
        InspectorSection(model?.promptLabel ?? "Prompt") {
            TextField(model?.promptLabel ?? "", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.raisedColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        }
    }

    private var generateBar: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            if let note = note ?? validationNote {
                Text(note)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: generate) {
                    Text(generateLabel)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Background.baseColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.smMd)
                        .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
                        .opacity((canGenerate && account.aiAllowed) ? AppTheme.Opacity.opaque : AppTheme.Opacity.medium)
                }
                .buttonStyle(.plain).focusable(false)
                .disabled(!canGenerate || !account.aiAllowed)
                .help(account.aiAllowed ? "" : "Add your Venice key to generate")

                agentMenu
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
    }

    private func clock(_ frame: Int) -> String {
        let total = Double(frame) / Double(max(1, editor.timeline.fps))
        let m = Int(total) / 60
        let s = Int(total) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var agentMenu: some View {
        Menu {
            Button {
                startAgentMusic(style: trimmedPrompt.isEmpty ? nil : trimmedPrompt)
            } label: { Label("Generate music for the timeline", systemImage: "music.note") }
            Menu {
                ForEach(["Cinematic", "Upbeat", "Ambient", "Tense", "Lo-fi"], id: \.self) { mood in
                    Button(mood) {
                        startAgentMusic(style: mood.lowercased())
                    }
                }
            } label: { Label("Mood", systemImage: "slider.horizontal.3") }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Agent Mode")
                Image(systemName: "chevron.down").font(.system(size: AppTheme.FontSize.xs))
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.aiGradient)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Background.raisedColor))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).strokeBorder(AppTheme.aiGradient.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.thin))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .help("Let Agent generate music for you. Choose a starter, or ask Agent in the chat.")
    }

    private func startAgentMusic(style: String?) {
        let service = editor.agentService
        service.newChat()
        service.draft = composeAgentPrompt(style: style)
        editor.agentPanelVisible = true
    }

    /// Fold the panel's current model, mode, and duration into the agent prompt
    /// so Agent Mode honors what the user set instead of re-deciding for them.
    private func composeAgentPrompt(style: String?) -> String {
        var prompt = style.map { "Generate \($0) music" } ?? "Generate music"
        prompt += " for my timeline and place it on an audio track aligned to the edit."
        guard let model else { return prompt }
        prompt += " Use the \(model.displayName) model (model id: \(model.id))."
        if isTextMode {
            prompt += " Make it about \(Int(textDuration.rounded())) seconds long."
        } else {
            let scope = editor.validSelectedTimelineRange != nil ? "the marked range" : "the whole timeline"
            prompt += " Score \(scope) from the video."
        }
        return prompt
    }

    private func generate() {
        note = nil
        guard let model else { return }
        let trimmed = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        let submission: MusicGenerationSubmission
        if isTextMode {
            let frameCount = max(1, Int(textDuration * Double(max(1, editor.timeline.fps))))
            submission = MusicGenerationSubmission(
                mode: .textToMusic, model: model, prompt: trimmed,
                source: .init(startFrame: textPlacementFrame, frameCount: frameCount),
                spanSeconds: textDuration, name: nil
            )
        } else {
            guard let source else { return }
            submission = MusicGenerationSubmission(
                mode: .videoToMusic, model: model, prompt: trimmed,
                source: source, spanSeconds: spanSeconds, name: nil
            )
        }

        isGenerating = true
        generatingLabel = (isTextMode ? MusicGenerationSubmission.Phase.generating : .exporting).label
        runTask = Task {
            do {
                try await submission.run(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onPhase: { generatingLabel = $0.label },
                    onPlaceholder: { generatingAssetId = $0 },
                    onFinished: { finishGenerating() }
                )
            } catch is CancellationError {
                finishGenerating()
            } catch {
                note = error.localizedDescription
                finishGenerating()
            }
        }
    }

    private func finishGenerating() {
        isGenerating = false
        generatingAssetId = nil
        runTask = nil
    }

    private func cancelGeneration() {
        if let id = generatingAssetId {
            editor.generationService.cancelGeneration(assetId: id, editor: editor)
        } else {
            runTask?.cancel()
            finishGenerating()
        }
    }
}

import SwiftUI

/// The single control center for choosing Venice models.
///
/// - Agent (inference): which Venice text model drives the in-app agent + MCP.
/// - Per-task defaults: the model used by default for image, text-to-video,
///   image-to-video, audio, and upscale generation.
/// - Enable/disable toggles: curate which models appear in the per-generation
///   dropdowns elsewhere in the app.
struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var traits = ModelTraitsCatalog.shared
    @Bindable private var transcription = TranscriptionPreferences.shared

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            if !catalog.isLoaded {
                loadingOrEmpty
            } else {
                agentSection
                defaultsSection
                transcriptionSection
                Divider().overlay(AppTheme.Border.subtleColor)
                searchBar
                toggleSections
            }
        }
    }

    @ViewBuilder
    private var loadingOrEmpty: some View {
        Text(VeniceKeychain.hasKey ? "Loading models…" : "Add your Venice API key (Venice tab) to load models.")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .padding(.top, AppTheme.Spacing.lg)
    }

    // MARK: - Agent (inference)

    private var agentSection: some View {
        sectionContainer(title: "Agent (inference)") {
            if catalog.textModels.isEmpty {
                Text("No text models available on this key.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                pickerRow(
                    title: "Chat model",
                    selectionId: prefs.agentModelId,
                    options: catalog.textModels.map { ($0.id, $0.displayName) },
                    onSelect: { prefs.agentModelId = $0 }
                )
                traitQuickPicks
            }
        }
    }

    /// Venice `/models/traits` quick-picks: one tap sets the agent model to the
    /// model Venice recommends for that trait (Fastest, Reasoning, …).
    @ViewBuilder
    private var traitQuickPicks: some View {
        let picks = traits.availableTraitPicks(in: Set(catalog.textModels.map(\.id)))
        if !picks.isEmpty {
            Divider().overlay(AppTheme.Border.subtleColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Quick pick")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: AppTheme.Spacing.xs)],
                    alignment: .leading,
                    spacing: AppTheme.Spacing.xs
                ) {
                    ForEach(picks, id: \.modelId) { pick in
                        Button {
                            prefs.agentModelId = pick.modelId
                        } label: {
                            Text(pick.label)
                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                                .foregroundStyle(prefs.agentModelId == pick.modelId
                                    ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xxs)
                                .background(
                                    Capsule().fill(prefs.agentModelId == pick.modelId
                                        ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.moderate)
                                        : Color.white.opacity(AppTheme.Opacity.subtle))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Use Venice's recommended model for: \(pick.label)")
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    // MARK: - Per-task generation defaults

    private var defaultsSection: some View {
        sectionContainer(title: "Generation defaults") {
            pickerRow(
                title: ModelPreferences.ModelTask.image.title,
                selectionId: prefs.defaultModel(for: .image),
                options: catalog.image.map { ($0.id, $0.displayName) },
                onSelect: { prefs.setDefaultModel($0, for: .image) }
            )
            pickerRow(
                title: ModelPreferences.ModelTask.textToVideo.title,
                selectionId: prefs.defaultModel(for: .textToVideo),
                options: catalog.video.filter { !$0.requiresReferenceImage }.map { ($0.id, $0.displayName) },
                onSelect: { prefs.setDefaultModel($0, for: .textToVideo) }
            )
            pickerRow(
                title: ModelPreferences.ModelTask.imageToVideo.title,
                selectionId: prefs.defaultModel(for: .imageToVideo),
                options: catalog.video.filter { $0.requiresReferenceImage }.map { ($0.id, $0.displayName) },
                onSelect: { prefs.setDefaultModel($0, for: .imageToVideo) }
            )
            pickerRow(
                title: ModelPreferences.ModelTask.audio.title,
                selectionId: prefs.defaultModel(for: .audio),
                options: catalog.audio.map { ($0.id, $0.displayName) },
                onSelect: { prefs.setDefaultModel($0, for: .audio) }
            )
            pickerRow(
                title: ModelPreferences.ModelTask.upscale.title,
                selectionId: prefs.defaultModel(for: .upscale),
                options: catalog.upscale.map { ($0.id, $0.displayName) },
                onSelect: { prefs.setDefaultModel($0, for: .upscale) }
            )
        }
    }

    // MARK: - Transcription backend

    private var transcriptionSection: some View {
        sectionContainer(title: "Transcription") {
            HStack(spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Use Venice cloud transcription")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Off uses on-device Speech (private, free). On uses Venice /audio/transcriptions for languages and accuracy it covers better; falls back to on-device on error.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Toggle("", isOn: $transcription.useVenice)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.vertical, AppTheme.Spacing.xs)
            if transcription.useVenice {
                Divider().overlay(AppTheme.Border.subtleColor)
                pickerRow(
                    title: "Transcription model",
                    selectionId: transcription.veniceModel,
                    options: TranscriptionPreferences.availableModels.map { ($0.id, $0.name) },
                    onSelect: { transcription.veniceModel = $0 ?? TranscriptionPreferences.availableModels[0].id }
                )
            }
        }
    }

    // MARK: - Default picker row

    @ViewBuilder
    private func pickerRow(
        title: String,
        selectionId: String?,
        options: [(String, String)],
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            Menu {
                Button("Auto (first available)") { onSelect(nil) }
                Divider()
                ForEach(options, id: \.0) { id, name in
                    Button(name) { onSelect(id) }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(currentLabel(selectionId: selectionId, options: options))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(options.isEmpty)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private func currentLabel(selectionId: String?, options: [(String, String)]) -> String {
        guard let selectionId, let match = options.first(where: { $0.0 == selectionId }) else {
            return "Auto"
        }
        return match.1
    }

    // MARK: - Enable / disable toggles

    private struct ToggleSection: Identifiable {
        let id: String
        let title: String
        let rows: [(id: String, name: String)]
    }

    private var toggleSectionData: [ToggleSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func filtered(_ rows: [(String, String)]) -> [(id: String, name: String)] {
            rows.filter { q.isEmpty || $0.1.lowercased().contains(q) }
                .map { (id: $0.0, name: $0.1) }
        }
        return [
            ToggleSection(id: "image", title: "Image", rows: filtered(catalog.image.map { ($0.id, $0.displayName) })),
            ToggleSection(id: "video", title: "Video", rows: filtered(catalog.video.map { ($0.id, $0.displayName) })),
            ToggleSection(id: "audio", title: "Audio", rows: filtered(catalog.audio.map { ($0.id, $0.displayName) })),
            ToggleSection(id: "upscale", title: "Upscale", rows: filtered(catalog.upscale.map { ($0.id, $0.displayName) })),
        ].filter { !$0.rows.isEmpty }
    }

    private var toggleSections: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            ForEach(toggleSectionData) { section in
                sectionContainer(title: "\(section.title) — enabled") {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: AppTheme.Spacing.md) {
                            Text(row.name)
                                .font(.system(size: AppTheme.FontSize.md))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Spacer(minLength: AppTheme.Spacing.lg)
                            Toggle("", isOn: Binding(
                                get: { prefs.isEnabled(row.id) },
                                set: { prefs.setEnabled(row.id, $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                        .padding(.vertical, AppTheme.Spacing.xs)
                        if index < section.rows.count - 1 {
                            Divider().overlay(AppTheme.Border.subtleColor)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
            )
        }
    }
}

import AppKit
import SwiftUI

/// Venice API key management — the single place to set the BYO key that powers
/// every AI feature (agent inference, image/video/audio generation, upscaling).
struct AccountPane: View {
    @Bindable private var account = AccountService.shared
    @State private var hasKey: Bool = false
    @State private var maskedKey: String = ""
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    private let consoleURL = URL(string: "https://venice.ai/settings/api")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            keyField
            statusRow
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Venice API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("A single Venice key powers the agent, image and video generation, audio, and upscaling. It is stored only in your macOS Keychain and sent directly to Venice.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { NSWorkspace.shared.open(consoleURL, configuration: .init(), completionHandler: nil) }) {
                    HStack(spacing: 2) {
                        Text("Get Venice API key")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    private var keyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            fieldBox
            trailingControl
        }
    }

    private var fieldBox: some View {
        SecureField(hasKey ? maskedKey : "Paste your Venice API key", text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(save)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)
    }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove API key")
        }
    }

    private var statusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(hasKey ? Color.green : AppTheme.Text.mutedColor)
                .frame(width: 8, height: 8)
            Text(hasKey ? "Key saved — AI features enabled." : "No key set — AI features are disabled.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(hasKey ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
        }
    }

    private func refresh() {
        let key = VeniceKeychain.load() ?? ""
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        VeniceKeychain.save(key)
        draft = ""
        isFocused = false
        refresh()
        ModelCatalog.shared.reload()
    }

    private func remove() {
        VeniceKeychain.delete()
        draft = ""
        refresh()
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }
}

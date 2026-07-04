import AppKit
import SwiftUI

/// Venice API key management — the single place to set the BYO key that powers
/// every AI feature (agent inference, image/video/audio generation, upscaling).
struct AccountPane: View {
    @Bindable private var account = AccountService.shared
    @State private var hasKey: Bool = false
    @State private var maskedKey: String = ""
    @State private var draft: String = ""
    @State private var confirmRemoval = false
    @State private var isValidating = false
    @State private var validationNote: String?
    @FocusState private var isFocused: Bool

    private let consoleURL = URL(string: "https://venice.ai/settings/api")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            keyField
            statusRow
            if hasKey {
                Divider().overlay(AppTheme.Border.subtleColor)
                balanceSection
            }
        }
        .onAppear {
            refresh()
            if hasKey { Task { await account.refreshUsage() } }
        }
    }

    @ViewBuilder
    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("BALANCE & USAGE")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
                if account.isLoadingUsage {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await account.refreshUsage() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh balance and usage")
                }
            }

            if let usage = account.veniceUsage {
                VStack(spacing: 0) {
                    if let usd = usage.usdBalance {
                        balanceRow("USD balance", String(format: "$%.2f", usd))
                    }
                    if let diem = usage.diemBalance {
                        balanceRow("DIEM balance", String(format: "%.2f", diem))
                    }
                    if let spend = usage.spendUSD, let days = usage.spendLookbackDays {
                        balanceRow("Spent (last \(days)d)", String(format: "$%.2f", spend))
                    }
                    if let tier = usage.tier {
                        balanceRow("Tier", tier.capitalized)
                    }
                    if !usage.accessPermitted {
                        balanceRow("Status", "Blocked — top up to continue")
                    }
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
            } else if let err = account.usageError {
                Text(err)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else if !account.isLoadingUsage {
                Text("Balance and usage will appear here.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    private func balanceRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
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
        if isValidating {
            ProgressView()
                .controlSize(.small)
        } else if !trimmed.isEmpty {
            Button("Save", action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button {
                confirmRemoval = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove API key")
            .alert("Remove your Venice API key?", isPresented: $confirmRemoval) {
                Button("Remove", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("AI features are disabled until you add a key again.")
            }
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill(hasKey ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(hasKey ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
            }
            if let validationNote {
                Text(validationNote)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private var statusText: String {
        if isValidating { return "Checking key with Venice…" }
        return hasKey ? "Key verified — AI features enabled." : "No key set — AI features are disabled."
    }

    private func refresh() {
        let key = VeniceKeychain.load() ?? ""
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !isValidating else { return }
        isValidating = true
        validationNote = nil
        Task { @MainActor in
            defer { isValidating = false }
            switch await Self.validate(key: key) {
            case .valid:
                commitKey(key)
            case .invalid:
                validationNote = "Venice rejected this key. Check it and try again."
            case .unreachable:
                // Can't verify without a network; keep the key rather than block setup.
                commitKey(key)
                validationNote = "Saved, but couldn't verify the key — Venice was unreachable."
            }
        }
    }

    private func commitKey(_ key: String) {
        VeniceKeychain.save(key)
        draft = ""
        isFocused = false
        refresh()
        ModelCatalog.shared.reload()
        Task { await account.refreshUsage() }
    }

    private enum KeyValidation { case valid, invalid, unreachable }

    private static func validate(key: String) async -> KeyValidation {
        do {
            _ = try await VeniceAPI(apiKey: key).rateLimitInfo()
            return .valid
        } catch VeniceAPI.VeniceError.http(let status, _) where status == 401 || status == 403 {
            return .invalid
        } catch {
            return .unreachable
        }
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

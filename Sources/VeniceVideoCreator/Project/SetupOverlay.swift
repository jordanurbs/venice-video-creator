import SwiftUI

/// First-run setup shown over the Home screen after the welcome card.
/// Every network-adjacent behavior ships off; this is where the user opts in.
struct SetupOverlay: View {
    let onDismiss: () -> Void

    @State private var backgroundUpdates = Updater.isBackgroundCheckEnabled
    @State private var skillCatalog = SkillCatalog.isEnabledPreference
    @State private var mcpServer = MCPService.isEnabledPreference
    @State private var seedanceConsent = ModelPreferences.shared.seedanceConsentGranted

    var body: some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
                .ignoresSafeArea()
            card
                .frame(width: 560)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("Set up Venice Video Creator")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Everything below is off until you turn it on. AI features talk only to api.venice.ai, with your key. There is no telemetry.")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                SettingsToggleRow(
                    title: "Check for updates automatically",
                    subtitle: "Fetches the update feed from GitHub at launch and hourly. Installing an update is always your call.",
                    isOn: $backgroundUpdates
                )
                SettingsToggleRow(
                    title: "Browse the community skill catalog",
                    subtitle: "Fetches the public skill list from GitHub when you open Skills settings.",
                    isOn: $skillCatalog
                )
                SettingsToggleRow(
                    title: "Run the local MCP server",
                    subtitle: "Lets local apps like Claude Desktop drive the editor over 127.0.0.1. Never reachable from the network.",
                    isOn: $mcpServer
                )
                SettingsToggleRow(
                    title: "Auto-consent to Seedance terms",
                    subtitle: "Attaches the consent Seedance requires for face-bearing media to every Seedance generation.",
                    isOn: $seedanceConsent
                )
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Adjust these anytime in Settings → General, Agent, and Models.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Continue") { apply() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppTheme.Spacing.sm)
        }
        .padding(AppTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    private func apply() {
        Updater.isBackgroundCheckEnabled = backgroundUpdates
        Updater.shared.backgroundCheckPreferenceChanged()
        SkillCatalog.isEnabledPreference = skillCatalog
        AppState.shared.setMCPEnabled(mcpServer)
        ModelPreferences.shared.seedanceConsentGranted = seedanceConsent
        onDismiss()
    }
}

import SwiftUI

struct PrivacyPane: View {
    @State private var backgroundUpdates = Updater.isBackgroundCheckEnabled
    @State private var skillCatalog = SkillCatalog.isEnabledPreference

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SettingsToggleRow(
                title: "Check for updates automatically",
                subtitle: "Fetches the update feed from GitHub at launch and hourly. Installing an update is always your call. Check for Updates in the app menu works either way.",
                isOn: $backgroundUpdates
            )
            .onChange(of: backgroundUpdates) { _, newValue in
                Updater.isBackgroundCheckEnabled = newValue
                Updater.shared.backgroundCheckPreferenceChanged()
            }

            SettingsToggleRow(
                title: "Browse the community skill catalog",
                subtitle: "Fetches the public skill list from GitHub when you open Skills settings. Installed skills keep working with this off.",
                isOn: $skillCatalog
            )
            .onChange(of: skillCatalog) { _, newValue in
                SkillCatalog.isEnabledPreference = newValue
            }

            Text("No telemetry. This app collects nothing and sends nothing anywhere except api.venice.ai for the AI features you invoke, using your key. Crash logs stay on this Mac in ~/Library/Logs/VeniceVideoCreator.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppTheme.Spacing.xs)

            Divider()
                .overlay(AppTheme.Border.subtleColor)
        }
    }
}

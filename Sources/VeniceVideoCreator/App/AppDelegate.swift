import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Start Sparkle updater
        _ = Updater.shared

        HomeWindowController.shared.showWindow(nil)
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
        }

        AppNotifications.configure()

        Transcription.onVeniceFallback = { _ in
            AppState.shared.activeProject?.editorViewModel.mediaPanelToast =
                MediaPanelToast(message: "Venice transcription unavailable — used on-device recognition instead.")
        }
        Transcription.onModelDownloadStart = { locale in
            let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            AppState.shared.activeProject?.editorViewModel.mediaPanelToast =
                MediaPanelToast(message: "Downloading the \(language) speech model — the first transcription takes longer.")
        }

        AppState.shared.startMCPService()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let exporting = ExportCoordinator.isExportActive
        let generating = GenerationBackend.activeJobCount
        guard exporting || generating > 0 else { return .terminateNow }

        let subject: String = switch (exporting, generating) {
        case (true, 0): "An export is in progress."
        case (false, 1): "A generation is in progress."
        case (false, let n): "\(n) generations are in progress."
        case (true, 1): "An export and a generation are in progress."
        case (true, let n): "An export and \(n) generations are in progress."
        }

        let alert = NSAlert()
        alert.messageText = subject
        alert.informativeText = (exporting && generating > 0) || generating > 1
            ? "Quitting cancels them." : "Quitting cancels it."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showHome()
        }
        return true
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createProjectInteractively()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showFeedback(_ sender: Any?) {
        FeedbackReporter.openIssue()
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }

    @MainActor
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showTutorial(_:)) {
            return AppState.shared.activeProject != nil
        }
        return true
    }
}

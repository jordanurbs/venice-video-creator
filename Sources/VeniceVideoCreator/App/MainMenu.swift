import AppKit

/// Builds the application main menu with keyboard shortcuts.
/// Called from AppDelegate to wire shortcuts into the responder chain.
@MainActor
enum MainMenuBuilder {

    static func buildMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenu())
        mainMenu.addItem(fileMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(playbackMenu())
        mainMenu.addItem(windowMenu())
        mainMenu.addItem(helpMenu())
        return mainMenu
    }

    // MARK: - App menu

    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Venice Video Editor")
        menu.addItem(withTitle: "About Venice Video Editor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = Updater.shared
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Venice Video Editor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Venice Video Editor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    // MARK: - File menu

    private static func fileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        let newItem = menu.addItem(withTitle: "New", action: #selector(AppDelegate.newProject(_:)), keyEquivalent: "n")
        newItem.target = NSApp.delegate
        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(EditorActions.newMediaFolder(_:)), keyEquivalent: "N")
        menu.addItem(newFolderItem)
        let openItem = menu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openProject(_:)), keyEquivalent: "o")
        openItem.target = NSApp.delegate
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        menu.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Revert to Saved…", action: Selector(("revertDocumentToSaved:")), keyEquivalent: "")
        menu.addItem(withTitle: "Browse All Versions…", action: Selector(("browseDocumentVersions:")), keyEquivalent: "")
        menu.addItem(.separator())

        let importItem = NSMenuItem(title: "Import Media…", action: #selector(EditorActions.importMedia(_:)), keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command]
        menu.addItem(importItem)

        menu.addItem(NSMenuItem(title: "Remove Unused Media…", action: #selector(EditorActions.removeUnusedMedia(_:)), keyEquivalent: ""))

        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export…", action: #selector(EditorActions.showExport(_:)), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command]
        menu.addItem(exportItem)

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())

        let selectForwardTrackItem = NSMenuItem(title: "Select Forward on Track", action: #selector(EditorActions.selectForwardOnTrack(_:)), keyEquivalent: "a")
        selectForwardTrackItem.keyEquivalentModifierMask = []
        menu.addItem(selectForwardTrackItem)

        let selectForwardAllItem = NSMenuItem(title: "Select Forward on All Tracks", action: #selector(EditorActions.selectForwardOnAllTracks(_:)), keyEquivalent: "a")
        selectForwardAllItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(selectForwardAllItem)

        menu.addItem(.separator())

        let splitItem = NSMenuItem(title: "Split at Playhead", action: #selector(EditorActions.splitAtPlayhead(_:)), keyEquivalent: "k")
        splitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(splitItem)

        let trimStartItem = NSMenuItem(title: "Trim Start to Playhead", action: #selector(EditorActions.trimStartToPlayhead(_:)), keyEquivalent: "q")
        trimStartItem.keyEquivalentModifierMask = []
        menu.addItem(trimStartItem)

        let trimEndItem = NSMenuItem(title: "Trim End to Playhead", action: #selector(EditorActions.trimEndToPlayhead(_:)), keyEquivalent: "w")
        trimEndItem.keyEquivalentModifierMask = []
        menu.addItem(trimEndItem)

        menu.addItem(.separator())

        // U+007F is what the Delete key actually produces; U+0008 never matches.
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(EditorActions.deleteSelectedClips(_:)), keyEquivalent: "\u{7F}")
        deleteItem.keyEquivalentModifierMask = []
        menu.addItem(deleteItem)

        let rippleDeleteItem = NSMenuItem(title: "Ripple Delete", action: #selector(EditorActions.rippleDeleteSelected(_:)), keyEquivalent: "\u{7F}")
        rippleDeleteItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(rippleDeleteItem)

        item.submenu = menu
        return item
    }

    // MARK: - View menu

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        let mediaItem = NSMenuItem(title: "Media Panel", action: #selector(EditorActions.toggleMediaPanel(_:)), keyEquivalent: "0")
        mediaItem.keyEquivalentModifierMask = [.command]
        menu.addItem(mediaItem)

        let inspectorItem = NSMenuItem(title: "Inspector", action: #selector(EditorActions.toggleInspectorPanel(_:)), keyEquivalent: "0")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(inspectorItem)

        let agentItem = NSMenuItem(title: "Agent Panel", action: #selector(EditorActions.toggleAgentPanel(_:)), keyEquivalent: "a")
        agentItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(agentItem)

        menu.addItem(.separator())

        let maximizeItem = NSMenuItem(title: "Maximize Focused Panel", action: #selector(EditorActions.toggleMaximizePanel(_:)), keyEquivalent: "`")
        maximizeItem.keyEquivalentModifierMask = []
        menu.addItem(maximizeItem)

        menu.addItem(.separator())
        menu.addItem(layoutSubmenuItem())
        menu.addItem(.separator())
        // System-standard shortcut; Cmd+F stays reserved for find.
        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreenItem)
        item.submenu = menu
        return item
    }

    // MARK: - Playback menu

    private static func playbackMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Playback")

        let playItem = NSMenuItem(title: "Play/Pause", action: #selector(EditorActions.playPause(_:)), keyEquivalent: " ")
        playItem.keyEquivalentModifierMask = []
        menu.addItem(playItem)

        menu.addItem(.separator())

        let left = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)

        let stepBackItem = NSMenuItem(title: "Step Backward", action: #selector(EditorActions.stepFrameBackward(_:)), keyEquivalent: left)
        stepBackItem.keyEquivalentModifierMask = []
        menu.addItem(stepBackItem)

        let stepForwardItem = NSMenuItem(title: "Step Forward", action: #selector(EditorActions.stepFrameForward(_:)), keyEquivalent: right)
        stepForwardItem.keyEquivalentModifierMask = []
        menu.addItem(stepForwardItem)

        let skipBackItem = NSMenuItem(title: "Skip Backward", action: #selector(EditorActions.skipFramesBackward(_:)), keyEquivalent: left)
        skipBackItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(skipBackItem)

        let skipForwardItem = NSMenuItem(title: "Skip Forward", action: #selector(EditorActions.skipFramesForward(_:)), keyEquivalent: right)
        skipForwardItem.keyEquivalentModifierMask = [.shift]
        menu.addItem(skipForwardItem)

        item.submenu = menu
        return item
    }

    // MARK: - Window menu

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }

    private static func layoutSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Layout")

        let defaultItem = NSMenuItem(title: LayoutPreset.default.label, action: #selector(EditorActions.setLayoutDefault(_:)), keyEquivalent: "1")
        defaultItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(defaultItem)

        let mediaItem = NSMenuItem(title: LayoutPreset.media.label, action: #selector(EditorActions.setLayoutMedia(_:)), keyEquivalent: "2")
        mediaItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(mediaItem)

        let verticalItem = NSMenuItem(title: LayoutPreset.vertical.label, action: #selector(EditorActions.setLayoutVertical(_:)), keyEquivalent: "3")
        verticalItem.keyEquivalentModifierMask = [.command]
        submenu.addItem(verticalItem)

        item.submenu = submenu
        return item
    }

    // MARK: - Help menu

    private static func helpMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(withTitle: "Tutorial", action: #selector(AppDelegate.showTutorial(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(AppDelegate.showKeyboardShortcuts(_:)), keyEquivalent: "?")
        menu.addItem(withTitle: "MCP Instructions", action: #selector(AppDelegate.showMCPInstructions(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Send Feedback…", action: #selector(AppDelegate.showFeedback(_:)), keyEquivalent: "")
        NSApp.helpMenu = menu
        item.submenu = menu
        return item
    }
}

/// Actions dispatched through the responder chain to reach the active EditorViewModel.
@MainActor @objc protocol EditorActions {
    func splitAtPlayhead(_ sender: Any?)
    func trimStartToPlayhead(_ sender: Any?)
    func trimEndToPlayhead(_ sender: Any?)
    func selectForwardOnTrack(_ sender: Any?)
    func selectForwardOnAllTracks(_ sender: Any?)
    func deleteSelectedClips(_ sender: Any?)
    func rippleDeleteSelected(_ sender: Any?)
    func importMedia(_ sender: Any?)
    func removeUnusedMedia(_ sender: Any?)
    func newMediaFolder(_ sender: Any?)
    func playPause(_ sender: Any?)
    func stepFrameForward(_ sender: Any?)
    func stepFrameBackward(_ sender: Any?)
    func skipFramesForward(_ sender: Any?)
    func skipFramesBackward(_ sender: Any?)
    func showExport(_ sender: Any?)
    func toggleMediaPanel(_ sender: Any?)
    func toggleInspectorPanel(_ sender: Any?)
    func toggleAgentPanel(_ sender: Any?)
    func toggleMaximizePanel(_ sender: Any?)
    func setLayoutDefault(_ sender: Any?)
    func setLayoutMedia(_ sender: Any?)
    func setLayoutVertical(_ sender: Any?)
}

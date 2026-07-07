import AppKit

/// Window controller that handles keyboard shortcuts via the responder chain.
/// Forwards actions to the EditorViewModel owned by VideoProject.
final class EditorWindowController: NSWindowController {
    let editorViewModel: EditorViewModel
    private nonisolated(unsafe) var keyMonitor: Any?
    private nonisolated(unsafe) var mouseMonitor: Any?

    init(editorViewModel: EditorViewModel, window: NSWindow) {
        self.editorViewModel = editorViewModel
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKeyDown(event) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let hitView = self.window?.contentView?.hitTest(event.locationInWindow)
            self.resignStaleFocus(hitView: hitView)
            self.handlePanelClick(hitView: hitView)
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Don't intercept keys when a text field has focus
        if isTextInputFocused {
            return false
        }

        let mods = event.modifierFlags
        let shift = mods.contains(.shift)
        let cmd = mods.contains(.command)
        // No command/option/control held (shift allowed) — the guard shared by
        // transport, selection, range-mark, and media-navigation shortcuts.
        let noCommandModifiers = mods.intersection([.command, .option, .control]).isEmpty
        // Command held with no option/control (shift allowed) — timeline zoom + jump.
        let commandOnly = cmd && mods.intersection([.option, .control]).isEmpty

        if editorViewModel.focusedPanel == .media, !shift,
           noCommandModifiers,
           let direction = mediaArrowDirection(for: event.keyCode) {
            editorViewModel.moveMediaSelection(direction: direction)
            return true
        }

        if event.keyCode == 126, cmd, editorViewModel.focusedPanel == .media {
            editorViewModel.mediaPanelNavigateUpRequestTick &+= 1
            return true
        }

        switch event.keyCode {
        case 0: // A key
            if editorViewModel.focusedPanel == .timeline, noCommandModifiers {
                editorViewModel.selectForwardFromCurrentSelection(scope: shift ? .allTracks : .track)
                return true
            }
            return false

        case 49: // Space
            guard noCommandModifiers,
                  editorViewModel.tour.currentStep == nil else { return false }
            editorViewModel.togglePlayback()
            return true

        case 123: // Left arrow
            if commandOnly { editorViewModel.seekToStart(); return true }
            guard noCommandModifiers else { return false }
            if shift { editorViewModel.skipBackward() } else { editorViewModel.stepBackward() }
            return true

        case 124: // Right arrow
            if commandOnly { editorViewModel.seekToEnd(); return true }
            guard noCommandModifiers else { return false }
            if shift { editorViewModel.skipForward() } else { editorViewModel.stepForward() }
            return true

        case 24: // = / + — zoom the timeline in (⌘=)
            if commandOnly { editorViewModel.zoomTimelineIn(); return true }
            return false

        case 27: // - — zoom the timeline out (⌘-)
            if commandOnly { editorViewModel.zoomTimelineOut(); return true }
            return false

        case 51: // Delete/Backspace
            return performScopedDelete(ripple: shift)

        case 8: // C key
            if !cmd {
                editorViewModel.toolMode = .razor
                return true
            }
            return false

        case 9: // V key
            if !cmd {
                editorViewModel.toolMode = .pointer
                return true
            }
            return false

        case 34: // I key
            if noCommandModifiers {
                editorViewModel.markTimelineRangeStart()
                return true
            }
            return false

        case 31: // O key
            if noCommandModifiers {
                editorViewModel.markTimelineRangeEnd()
                return true
            }
            return false

        case 33: // [ key
            guard mods.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            editorViewModel.trimStartToPlayhead()
            return true

        case 30: // ] key
            guard mods.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            editorViewModel.trimEndToPlayhead()
            return true

        case 50: // ` (backtick) — toggle panel maximize
            if mods.intersection([.command, .option, .control, .shift]).isEmpty {
                toggleMaximizePanelAction()
                return true
            }
            return false

        case 36: // Return / Enter
            if editorViewModel.focusedPanel == .media,
               editorViewModel.selectedFolderIds.count == 1,
               let folderId = editorViewModel.selectedFolderIds.first {
                editorViewModel.mediaPanelOpenFolderId = folderId
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            return false

        case 53: // Escape
            // The tour and sheets own Esc — let it through so .cancelAction
            // and .onExitCommand can fire.
            if editorViewModel.tour.currentStep != nil { return false }
            if window?.attachedSheet != nil { return false }
            if editorViewModel.pendingSwapClipId != nil {
                editorViewModel.cancelMediaSwap()
                return true
            }
            if editorViewModel.cropEditingActive {
                editorViewModel.cropEditingActive = false
                return true
            }
            if editorViewModel.maximizedPanel != nil {
                editorViewModel.maximizedPanel = nil
                return true
            }
            guard !editorViewModel.selectedClipIds.isEmpty
                || editorViewModel.selectedTimelineRange != nil
                || editorViewModel.toolMode != .pointer else { return false }
            editorViewModel.selectedClipIds.removeAll()
            editorViewModel.clearTimelineRange()
            editorViewModel.toolMode = .pointer
            return true

        default:
            return false
        }
    }

    /// Whether the focused panel holds something Delete would remove — the single
    /// source of truth for menu-item enablement and delete gating.
    private var hasDeletableSelection: Bool {
        switch editorViewModel.focusedPanel {
        case .media:
            return !editorViewModel.selectedFolderIds.isEmpty || !editorViewModel.selectedMediaAssetIds.isEmpty
        case .timeline:
            return !editorViewModel.selectedClipIds.isEmpty || editorViewModel.selectedGap != nil
        case .preview, .inspector, .agent, nil:
            return false
        }
    }

    /// Single Delete implementation shared by the key monitor and menu items —
    /// scoped to the focused panel so a stale selection elsewhere never dies.
    @discardableResult
    private func performScopedDelete(ripple: Bool) -> Bool {
        switch editorViewModel.focusedPanel {
        case .media:
            if !editorViewModel.selectedFolderIds.isEmpty {
                editorViewModel.deleteFolders(ids: editorViewModel.selectedFolderIds)
            }
            if !editorViewModel.selectedMediaAssetIds.isEmpty {
                editorViewModel.deleteSelectedMediaAssets()
            }
            return true
        case .timeline:
            if ripple {
                if editorViewModel.selectedGap != nil {
                    editorViewModel.rippleDeleteSelectedGap()
                } else {
                    editorViewModel.rippleDeleteSelectedClips()
                }
            } else {
                editorViewModel.deleteSelectedClips()
            }
            return true
        case .preview, .inspector, .agent, nil:
            return false
        }
    }

    private func mediaArrowDirection(for keyCode: UInt16) -> EditorViewModel.MediaSelectionDirection? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    private var isTextInputFocused: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        if let textField = responder as? NSTextField { return textField.isEditable }
        return false
    }

    private func handlePanelClick(hitView: NSView?) {
        var view = hitView
        while let v = view {
            if let panel = EditorViewModel.FocusedPanel(accessibilityID: v.accessibilityIdentifier()) {
                editorViewModel.focusedPanel = panel
                if panel == .media { editorViewModel.selectedClipIds.removeAll() }
                if panel == .timeline {
                    editorViewModel.selectedMediaAssetIds.removeAll()
                    editorViewModel.selectedFolderIds.removeAll()
                }
                return
            }
            view = v.superview
        }
    }

    /// Clear stale first-responder focus before the click is dispatched.
    private func resignStaleFocus(hitView: NSView?) {
        // Don't disturb a deliberate click into a text input.
        if hitView is NSTextView || hitView is NSTextField { return }
        guard let responder = window?.firstResponder,
              let view = responder as? NSView, view !== window?.contentView else { return }
        window?.makeFirstResponder(nil)
    }
}

// MARK: - EditorActions (responder chain)

extension EditorWindowController: EditorActions {
    @objc func splitAtPlayhead(_ sender: Any?) { editorViewModel.splitAtPlayhead() }
    @objc func trimStartToPlayhead(_ sender: Any?) { editorViewModel.trimStartToPlayhead() }
    @objc func trimEndToPlayhead(_ sender: Any?) { editorViewModel.trimEndToPlayhead() }
    @objc func selectForwardOnTrack(_ sender: Any?) { editorViewModel.selectForwardFromCurrentSelection(scope: .track) }
    @objc func selectForwardOnAllTracks(_ sender: Any?) { editorViewModel.selectForwardFromCurrentSelection(scope: .allTracks) }
    @objc func deleteSelectedClips(_ sender: Any?) { performScopedDelete(ripple: false) }
    @objc func rippleDeleteSelected(_ sender: Any?) { performScopedDelete(ripple: true) }
    @objc func playPause(_ sender: Any?) { editorViewModel.togglePlayback() }
    @objc func stepFrameForward(_ sender: Any?) { editorViewModel.stepForward() }
    @objc func stepFrameBackward(_ sender: Any?) { editorViewModel.stepBackward() }
    @objc func skipFramesForward(_ sender: Any?) { editorViewModel.skipForward() }
    @objc func skipFramesBackward(_ sender: Any?) { editorViewModel.skipBackward() }

    @objc func importMedia(_ sender: Any?) {
        editorViewModel.mediaPanelVisible = true
        editorViewModel.showMediaPanelMediaTab()
        editorViewModel.mediaPanelImportRequestTick &+= 1
    }

    @objc func removeUnusedMedia(_ sender: Any?) {
        editorViewModel.removeUnusedMedia()
    }

    @objc func newMediaFolder(_ sender: Any?) {
        editorViewModel.mediaPanelVisible = true
        editorViewModel.showMediaPanelMediaTab()
        editorViewModel.mediaPanelNewFolderRequestTick &+= 1
    }

    @objc func showExport(_ sender: Any?) {
        editorViewModel.showExportDialog = true
    }

    @objc func copy(_ sender: Any?) {
        guard canHandleClipboardShortcut(),
              !editorViewModel.selectedClipIds.isEmpty else { return }
        editorViewModel.copySelectedClipsToClipboard()
    }

    @objc func cut(_ sender: Any?) {
        guard canHandleClipboardShortcut(),
              !editorViewModel.selectedClipIds.isEmpty else { return }
        editorViewModel.copySelectedClipsToClipboard()
        editorViewModel.deleteSelectedClips()
    }

    @objc func paste(_ sender: Any?) {
        if editorViewModel.focusedPanel == .media {
            editorViewModel.mediaPanelPasteRequestTick &+= 1
            return
        }
        guard canHandleClipboardShortcut(),
              editorViewModel.canPasteClips else { return }
        editorViewModel.pasteClipsAtPlayhead()
    }

    private func canHandleClipboardShortcut() -> Bool {
        editorViewModel.focusedPanel == .timeline
    }

    @objc func focusMediaPanel(_ sender: Any?) {
        editorViewModel.mediaPanelVisible = true
        editorViewModel.focusedPanel = .media
    }
    @objc func focusPreviewPanel(_ sender: Any?) { editorViewModel.focusedPanel = .preview }
    @objc func focusTimelinePanel(_ sender: Any?) { editorViewModel.focusedPanel = .timeline }
    @objc func focusInspectorPanel(_ sender: Any?) {
        editorViewModel.inspectorPanelVisible = true
        editorViewModel.focusedPanel = .inspector
    }

    @objc func toggleMediaPanel(_ sender: Any?) { editorViewModel.mediaPanelVisible.toggle() }
    @objc func toggleInspectorPanel(_ sender: Any?) { editorViewModel.inspectorPanelVisible.toggle() }
    @objc func toggleAgentPanel(_ sender: Any?) { editorViewModel.agentPanelVisible.toggle() }
    @objc func toggleMaximizePanel(_ sender: Any?) { toggleMaximizePanelAction() }
    @objc func setLayoutDefault(_ sender: Any?) { editorViewModel.layoutPreset = .default }
    @objc func setLayoutMedia(_ sender: Any?) { editorViewModel.layoutPreset = .media }
    @objc func setLayoutVertical(_ sender: Any?) { editorViewModel.layoutPreset = .vertical }

    private func toggleMaximizePanelAction() {
        if editorViewModel.maximizedPanel != nil {
            editorViewModel.maximizedPanel = nil
        } else if let panel = editorViewModel.focusedPanel {
            editorViewModel.maximizedPanel = panel
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleMediaPanel(_:)):
            menuItem.state = editorViewModel.mediaPanelVisible ? .on : .off
            return true
        case #selector(toggleInspectorPanel(_:)):
            menuItem.state = editorViewModel.inspectorPanelVisible ? .on : .off
            return true
        case #selector(toggleAgentPanel(_:)):
            menuItem.state = editorViewModel.agentPanelVisible ? .on : .off
            return true
        case #selector(toggleMaximizePanel(_:)):
            menuItem.state = editorViewModel.maximizedPanel != nil ? .on : .off
            return editorViewModel.maximizedPanel != nil || editorViewModel.focusedPanel != nil
        case #selector(setLayoutDefault(_:)):
            menuItem.state = editorViewModel.layoutPreset == .default ? .on : .off
            return true
        case #selector(setLayoutMedia(_:)):
            menuItem.state = editorViewModel.layoutPreset == .media ? .on : .off
            return true
        case #selector(setLayoutVertical(_:)):
            menuItem.state = editorViewModel.layoutPreset == .vertical ? .on : .off
            return true
        case #selector(copy(_:)), #selector(cut(_:)):
            return canHandleClipboardShortcut() && !editorViewModel.selectedClipIds.isEmpty
        case #selector(selectForwardOnTrack(_:)), #selector(selectForwardOnAllTracks(_:)):
            return editorViewModel.focusedPanel == .timeline && !editorViewModel.selectedClipIds.isEmpty
        case #selector(deleteSelectedClips(_:)), #selector(rippleDeleteSelected(_:)):
            return !isTextInputFocused && hasDeletableSelection
        case #selector(trimStartToPlayhead(_:)), #selector(trimEndToPlayhead(_:)):
            return !isTextInputFocused
                && editorViewModel.focusedPanel == .timeline
                && !editorViewModel.selectedClipIds.isEmpty
        case #selector(playPause(_:)):
            return !isTextInputFocused && editorViewModel.tour.currentStep == nil
        case #selector(stepFrameForward(_:)), #selector(stepFrameBackward(_:)),
             #selector(skipFramesForward(_:)), #selector(skipFramesBackward(_:)):
            return !isTextInputFocused
        case #selector(paste(_:)):
            if editorViewModel.focusedPanel == .media {
                return MediaTab.clipboardHasImportableMedia()
            }
            return canHandleClipboardShortcut() && editorViewModel.canPasteClips
        default:
            return true
        }
    }
}

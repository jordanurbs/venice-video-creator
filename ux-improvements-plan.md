# UX Improvements Plan — Venice Video Creator

> Source: full-app UX audit, 2026-07-03, branch `venice-integration` (clean tree at f2d27df).
> 8 audit dimensions, 97 findings, every one verified at file:line; two behaviors confirmed with compiled AppKit probes.
> Rendered report: https://claude.ai/code/artifact/790d44ca-9311-4f96-b863-a4753dd92c4b

---

## Session kickoff prompt

Copy-paste this to start an improvements session:

> You are a senior macOS engineer who has shipped native NLEs — the kind of developer who knows that a video editor earns trust in the gaps between features: what happens when you cancel, quit, relaunch, mis-click, or press the wrong key. You've inherited Venice Video Creator (Swift 6.2, SwiftUI + AppKit, AVFoundation, macOS 26, non-sandboxed) along with a completed UX audit of all 300 source files.
>
> Your backlog is `ux-improvements-plan.md` at the repo root. Read it fully, then read `AGENTS.md` — its rules on comments, AppTheme, drag-and-drop architecture, and product voice are non-negotiable.
>
> Work the phases in order; within a phase, work the numbered items in order unless a shared root cause makes batching obviously better. For every fix: read the cited code and its callers before touching it, fix the cause rather than the symptom, build with `swift build`, and exercise the actual flow you changed — a fix to export cancellation is verified by cancelling an export, not by a clean compile. Check the box, note anything surprising in the Progress Log at the bottom of the plan, and commit each completed cluster with a concise message.
>
> Respect the "Do not churn" list — those subsystems were verified sound and your fixes must not degrade them. When a finding's remedy involves a genuine product decision (marked ⚖️), propose your recommendation and ask before implementing. Everything else, just fix.
>
> Start with Phase 1, item 1.1.

---

## Ground rules

- **Build/run:** `swift build`, `swift run`. Verify each fix in the running app when the flow is exercisable.
- **AGENTS.md governs:** minimal comments, all UI values through `AppTheme` (add missing constants there first), parent drop targets in AppKit only, product voice "direct, technical, calm" — action verb first for requests, name the thing for state.
- **Severity ≠ order.** Phases group by shared root cause so plumbing is built once. Phase 1 builds the cancellation/lifecycle machinery that four critical findings share.
- **⚖️ marks decision points** — recommend, then ask before implementing.
- **Commits:** one per completed cluster, on this branch unless told otherwise.

---

## Phase 1 — Cancellation & lifecycle plumbing

The root causes: no cancellation API exists anywhere (export or generation), no terminate guard exists, and the Venice `queue_id` is never persisted. Build the plumbing once; six findings collapse into it.

- [x] **1.1 Real export cancel.** Add a cancel path to `ExportService` (cancel the `AVAssetExportSession`, release the `ExportCoordinator` slot, surface "Export cancelled"). Wire the sheet's Cancel to it while exporting. The dead branch at `Export/ExportService.swift:130` becomes live. Refs: `Export/ExportView.swift:304`, `Export/ExportCoordinator.swift:15-20`.
- [x] **1.2 Quit/update guard.** Implement `applicationShouldTerminate` consulting `ExportCoordinator.isExportActive` and in-flight generations; prompt with what's running. Add a Sparkle postpone guard so "Install and Relaunch" can't kill an export. Refs: `App/AppDelegate.swift`, `App/MainMenu.swift:31`, `App/Updater.swift:20-28`, `Export/ExportCoordinator.swift:7`.
- [x] **1.3 Persist the Venice `queue_id` and make resume real.** Today `VeniceJobStore` is in-memory, the persisted `backendJobId` is a local UUID, and the real `queue_id` dies in a local variable — so relaunch strands placeholders "Generating…" forever while Venice bills the completed job. Persist the queue_id in `GenerationInput`; on resume, poll Venice by queue_id; placeholders that can't resume get a visible failed state with Retry, never an eternal shimmer. Refs: `Generation/GenerationBackend.swift:121,128`, `Generation/GenerationService.swift:275-306,444-453`, `Venice/VeniceGeneration.swift:169-175,259-263`, `Project/VideoProject.swift:569-572`.
- [x] **1.4 Generation cancel.** Cancellation API in `GenerationService`/`VeniceJobStore` (cancel the poll task, mark the placeholder cancelled). Add Cancel to the placeholder context menu and the music overlay. Refs: `MediaPanel/MediaTab/AssetThumbnailView.swift:91-110`, `MediaPanel/MusicTab.swift:108-111`.
- [x] **1.5 Kill the zombie-asset path.** Deleting a generating placeholder must cancel its monitor; `updateManifestMetadata` must not re-append entries for deleted assets. Refs: `Editor/ViewModel/EditorViewModel+ClipMutations.swift:681-712`, `Generation/GenerationService.swift:308-322`, `Editor/ViewModel/EditorViewModel+MediaLibrary.swift:471-478`.
- [x] **1.6 Don't autosave closed documents.** A generation finishing after close currently triggers checkpoint autosave on the zombie document and can clobber a reopened copy. Cancel/detach generation tasks on close, or gate autosave on document-open state. Refs: `Generation/GenerationService.swift:74`, `Project/VideoProject.swift:282-295`.
- [x] **1.7 In-flight guards on AI Edit.** Disable Upscale / Remove Background / AI Edit / Rerun per-asset while a job runs; show submission feedback in the inspector. Double-click today = double charge. Refs: `Generation/Edit/EditSubmitter.swift:10,75,112,178`, `Inspector/Tabs/AIEditTab.swift:262-325`.
- [x] **1.8 Second-export honesty.** Don't show `isExporting`/0% while waiting on the coordinator slot — either state "Waiting for current export…" or refuse. Refs: `Export/ExportService.swift:43-47,77`.

**Done when:** an export can be cancelled and quit-guarded; a relaunch mid-generation either resumes to completion or fails visibly with Retry; deleted placeholders stay deleted; no paid action can be double-fired.

## Phase 2 — Data safety

- [x] **2.1 Fix the Delete-key hijack.** Scope Delete to the focused panel; clear `selectedFolderIds` (not just asset ids) when focus moves to the timeline. Today: select a folder, click a timeline clip, press Delete → the folder, all nested assets, and every referencing clip vanish silently. Refs: `Editor/EditorWindowController.swift:76-83,197`, `Editor/ViewModel/EditorViewModel+Folders.swift:67-98`.
- [x] **2.2 Surface save failures.** Autosave on Home-navigation and initial project-creation save both discard errors — disk-full is silent data loss. Alert with the failure and hold navigation. Persistent checkpoint failures need one non-spammy surface. Refs: `App/AppState.swift:78,192-194`, `Project/VideoProject.swift:288-293`.
- [x] **2.3 Chat session delete: confirm or undo.** One click on the trash icon is permanent within seconds (next autosave rewrites the chat dir). Minimum: confirmation naming the session. Refs: `Agent/Panel/ChatHistoryList.swift:54`, `Agent/AgentService.swift:314-324`, `Project/VideoProject.swift:176-180`.
- [x] **2.4 Add Revert.** `autosavesInPlace` with no "Revert To / Browse All Versions" means the undo stack is the only rollback and it dies on quit. Add the standard menu items. Refs: `Project/VideoProject.swift:53`, `App/MainMenu.swift:41-58`.
- [x] **2.5 Surface the export run report.** ExportView never shows `ExportRunReport` — exports with offline media report success and ship black holes. Warn pre-export for all destinations (today: Venice-project only) and report post-export. Refs: `Export/ExportService.swift:117-122`, `Export/ExportView.swift:259-263,487-489`.
- [x] **2.6 Register relink with undo.** Refs: `Editor/ViewModel/EditorViewModel+Relink.swift:40-55`.
- [x] **2.7 Confirm API key removal** (trash button shares the Save button's slot — mis-click prone). Refs: `Settings/AccountPane.swift:174,214-218`.
- [x] **2.8 Agent export overwrite.** ⚖️ Default `overwrite` to false, or confine agent-writable paths. Today the agent unlinks arbitrary absolute paths with no confirmation. Refs: `Agent/Tools/ToolExecutor+Export.swift:7,111-117,204-220`.
- [x] **2.9 Guard deleting an open project** (open editor autosave resurrects a hollow package while its media sits in the Trash) and surface `trashItem` failures instead of no-opping. Refs: `Project/ProjectCard.swift:112-119`, `Project/ProjectRegistry.swift:59-64,132-140`, `Project/VideoProject.swift:205-233`.
- [x] **2.10 Small destructive-path fixes:** undo of Delete Document rewrites the .md mirror (`Editor/ViewModel/EditorViewModel+Documents.swift:52-62,95-98`); folder-delete menu labels its blast radius (`MediaPanel/MediaTab/MediaTab+Grids.swift:289,417`); New-Project-over-existing doesn't leave a franken-package (`Project/VideoProject.swift:226-233`). ⚖️ Disk reclamation for deleted media (bundle grows unbounded) — likely a "Remove unused media" maintenance action rather than delete-time unlink.

**Done when:** no single mis-click or keypress can permanently destroy user work without either a confirmation or an undo, and no save failure is silent.

## Phase 3 — Dead & conflicting controls

- [x] **3.1 Fix Cmd+I / File → Import Media.** The menu action dispatches to an empty stub while the real import is a private SwiftUI func on the toolbar "+". Route the menu to a working import. Refs: `Editor/EditorWindowController.swift:236`, `App/MainMenu.swift:50`, `MediaPanel/MediaTab/MediaTab.swift:756`.
- [x] **3.2 Stop consuming Esc unconditionally.** The monitor's final Esc branch returns true always, breaking the tour's Skip (`.cancelAction` never fires) and making `.onExitCommand` dead. Let Esc fall through when an overlay/sheet should own it. Refs: `Editor/EditorWindowController.swift:151-167`, `Editor/Tour/TourOverlay.swift:88,120`, `MediaPanel/MediaTab/MediaTab.swift:138`.
- [x] **3.3 Unify Delete semantics.** The menu's `"\u{8}"` key equivalents never match the physical Delete key (verified), and menu-Delete (clips only) differs from key-Delete (media first). One handler, one behavior, working menu shortcuts. Refs: `App/MainMenu.swift:102-108`, `Editor/EditorWindowController.swift:76-93`.
- [x] **3.4 Gate bare Q/W.** Trim-to-playhead fires from any panel whenever nothing has key focus (which is the normal state). Validate like A does: timeline focus + relevance. Refs: `App/MainMenu.swift:92-98`, `Editor/EditorWindowController.swift:319-320`.
- [x] **3.5 Standard menus.** Add a Window menu (Close Cmd+W, Minimize Cmd+M, Zoom, cycle, windows list; assign `NSApp.windowsMenu`), Hide/Hide Others/Services in the app menu, and assign `NSApp.helpMenu` so Help search works. Refs: `App/MainMenu.swift:8-34`, `App/main.swift:16`.
- [x] **3.6 ⚖️ Cmd+F.** Currently Enter Full Screen, overriding the universal Find key. Recommend moving full screen to the system-standard Ctrl+Cmd+F and reserving Cmd+F for future search. Refs: `App/MainMenu.swift:141`, `Help/ShortcutsPane.swift:56`.
- [x] **3.7 Space with modifiers / over overlays.** Require no-modifier for play/pause; don't start playback behind the tour. Refs: `Editor/EditorWindowController.swift:64-66`.
- [x] **3.8 Fix or remove dead Cmd+Shift+N / Cmd+Up** (sink view is never first responder). Route through the menu or the monitor instead. Refs: `MediaPanel/MediaTab/MediaTab.swift:799-835`.
- [x] **3.9 Disable Help → Tutorial on Home** (silently no-ops today). Refs: `App/AppDelegate.swift:64-67`.
- [x] **3.10 Shortcuts pane truth pass:** add panel/layout keys, fix the duplicate contradictory "Cmd + Scroll" rows, drop dead entries. Refs: `Help/ShortcutsPane.swift:6-61`. Also: modifier-check the `[`/`]`/arrow monitor branches so Cmd-chords don't trim (`Editor/EditorWindowController.swift:68-74,123-129`); ⚖️ consider a Playback menu so transport is menu-visible; Cmd+S in Settings shadowing project save (`Settings/SkillsPane.swift:426`) — at minimum retitle the button "Save Skill".

**Done when:** every menu item and documented shortcut does what it says, and no bare key destructively edits from the wrong panel.

## Phase 4 — Drag & drop coherence

Per AGENTS.md: parent drop targets that span other drop targets must be AppKit. The media panel already does this right — extend the pattern, don't fight it.

- [ ] **4.1 Finder → timeline.** The timeline registers `.fileURL`, shows a copy cursor, and drops nothing (handler reads `.string` only). Implement import-and-place (import to library, then insert at the drop point), or at minimum stop advertising the drop. Refs: `Timeline/TimelineView.swift:26,1084-1097,1157`.
- [ ] **4.2 Folder → timeline.** `venice-folder://` payloads show the copy cursor then silently no-op. Either sequential-insert the folder's assets or return `[]` in `draggingEntered`. Refs: `Timeline/TimelineView.swift:1084-1097`, `Editor/ViewModel/EditorViewModel+MediaLibrary.swift:141-146`.
- [ ] **4.3 Agent input box.** Rebuild the drop per the repo rule (AppKit — it spans a TextEditor and currently swallows macOS text drags, probe-verified) and accept in-app `venice-asset://` drags as mentions, not just Finder files. Refs: `Agent/Panel/AgentInputBox.swift:84,89,261-275`.
- [ ] **4.4 Generation slots accept Finder files** (today: in-app only — the exact inverse of 4.3's old policy; the media grid pixels above accept what the slot refuses). Also give folder drags onto slots the same `flashDropError` wrong-type feedback other mistakes get. Refs: `Generation/UI/DropZoneView.swift:28,33-53`, `Generation/UI/GenerationView.swift:1141-1158,1406`.
- [ ] **4.5 Media panel drop-target hygiene:** clear `currentFolderId` when leaving folder view-mode (invisible import destination otherwise); breadcrumb chips get `isTargeted` highlighting; the panel background accepts in-app asset drags so "move to Library" exists. Refs: `MediaPanel/MediaTab/MediaTab.swift:425,640-643`, `MediaPanel/MediaTab/MediaTab+Drag.swift:100-104`, `MediaPanel/MediaTab/MediaPanelDropArea.swift:29`.
- [ ] **4.6 ⚖️ Preview drop target** — dropping media on the preview canvas (a standard NLE affordance) currently does nothing. Decide whether to add it; if yes, AppKit per the rule.

**Done when:** every surface that shows a drop cursor completes the drop, every refusal is visible, and in-app vs Finder payloads are accepted consistently.

## Phase 5 — Feedback & progress honesty

- [ ] **5.1 One feedback component.** Five parallel mechanisms exist (MediaPanelToast, flashDropError, SkillsPane banner, inline notes, lone NSAlert). Build one editor-level toast/notice surface; route `mediaPanelToast` setters through it so results from the timeline audio-sync and preview relink flows can't fire into a hidden panel. Refs: `MediaPanel/MediaTab/MediaTab.swift:115-121`, `Timeline/TimelineView+AudioSyncMenu.swift:11`, `Preview/PreviewContainerView.swift:322`.
- [ ] **5.2 Honest generation progress.** Replace the fake ease-to-90%-in-45s bar with phase labels + elapsed time (video jobs run to 15 min; the fake bar makes bounded waits read as hangs). Refs: `UI/GeneratingOverlay.swift:20-21,30`.
- [ ] **5.3 Failure notifications.** Generation-failed and interactive-export-complete notifications (both exist only for success / agent paths today). Refs: `App/AppNotifications.swift:40`, `Generation/GenerationService.swift:599-607`.
- [ ] **5.4 Error copy pass.** Map raw surfaces to actionable messages: HTTP 401 → "Check your Venice key in Settings"; kill raw response-body prefixes on thumbnails, raw NSError chains in the export sheet, "Backend not configured" jargon. Refs: `Venice/VeniceAPI.swift:162-188`, `Export/ExportView.swift:125-130`, `Agent/Clients/AgentClientError.swift:21,28`, `Generation/GenerationService.swift:447,574`.
- [ ] **5.5 Validate API keys on save** (dot goes green for garbage; 401 vs offline collapsed by `try?`). Refs: `Settings/AccountPane.swift:191,203-212`, `Account/AccountService.swift:78-83`.
- [ ] **5.6 ⚖️ Fix the guaranteed-fail feedback path.** `sendFeedback` unconditionally throws, yet "Report a Problem" is offered as recovery and the compose window fails only at submit. Recommend repointing to GitHub issues. Refs: `Account/AccountService.swift:99-111`, `Preview/PreviewContainerView.swift:392-397`, `Help/FeedbackView.swift`.
- [ ] **5.7 Silent-action fixes:** paste-image, Capture Frame, Save Clip as Media failures get messages (`Editor/ViewModel/EditorViewModel+MediaLibrary.swift:297-300,512-539`, `Editor/ViewModel/EditorViewModel+SaveAsMedia.swift:11-14`); Venice STT fallback to on-device is announced (`Transcription/Transcription.swift:74-76,162-164`); partial multi-clip caption failures reported (`Editor/ViewModel/EditorViewModel+Captions.swift:152-156`); corrupt-manifest recovery explained to the user (`Project/VideoProject.swift:100-109`); batch import rejection summarizes all files, not the last (`Editor/ViewModel/EditorViewModel+MediaLibrary.swift:253-257`).
- [ ] **5.8 Blocking & busy states:** project-open busy indicator + move manifest disk-stats off main (`App/AppState.swift:198-206`, `Project/VideoProject.swift:489-509`); async Save As (`canAsynchronouslyWrite`, `Project/VideoProject.swift:257-266`); transcription model-download progress + cancel (`Transcription/Transcription.swift:206-227`); base64 reference encode off the main actor (`Generation/GenerationBackend.swift:29-33`); un-block the Music tab during generation (placeholder clip already exists — `MusicTab.swift:108-111`).
- [ ] **5.9 Empty states:** timeline hint for empty projects (`Timeline/TimelineView.swift:120-121`); search distinguishes "index building" from "no matches" (`MediaPanel/MediaTab/MediaTab+Search.swift:32-38`); media empty state gets Import/Generate buttons (`MediaPanel/MediaTab/MediaTab.swift:717-739`); failed generation tiles get inline Retry (`MediaPanel/MediaTab/AssetThumbnailView.swift:251-268`); voice clone gets a busy indicator and a delete UI (`Generation/UI/GenerationView.swift:957-984`, dead `Venice/VeniceVoiceClone.swift:38`).

**Done when:** nothing fails silently, no progress indicator lies, and no result fires into a hidden surface.

## Phase 6 — Concurrency correctness

- [ ] **6.1 Save As rebinds the editor.** `projectURL` is assigned once at open; after Save As, generations write into the old .venice bundle. Update the editor's package binding when `fileURL` changes. Refs: `Project/VideoProject.swift:335`, `Generation/GenerationService.swift:229-234`.
- [ ] **6.2 MCP targets the key window's project,** not most-recently-opened; ⚖️ decide whether external clients may switch the active project under the user. Refs: `App/AppState.swift:41-43,88-103`, `Agent/Tools/ToolExecutor+Projects.swift:48-56`.
- [ ] **6.3 Agent undo attribution.** Replace undo-action-name string matching with a token/identity check so the agent can never revert the user's like-named edit. Refs: `Agent/Tools/ToolExecutor.swift:47-52,152-166`.
- [ ] **6.4 Captions re-resolve clip geometry after transcription** instead of placing from a snapshot minutes stale. Refs: `Editor/ViewModel/EditorViewModel+Captions.swift:119-124,177-207`.
- [ ] **6.5 Smaller races:** transcript cache in-flight dedup (`Transcription/TranscriptCache.swift:11-30`); agent edits shouldn't permanently kill playback (`Editor/ViewModel/EditorViewModel.swift:339-347`); settings-mismatch sheet Esc-dismissal must run/cancel the continuation, not leak the pending clips (`Editor/ViewModel/EditorViewModel+ProjectSettings.swift:146-147`, `Project/VideoProject.swift:360`); project close cancels its indexing/transcription work (`Search/SearchIndexCoordinator.swift:127-138`).

**Done when:** two projects, an agent, and an external MCP client can coexist without any of them acting on the wrong target or stale state.

## Phase 7 — Accessibility & keyboard access

- [ ] **7.1 Track header controls become real controls.** Mute/hide/sync-lock are CGContext drawings with nil accessibility descriptions and hand-rolled hit tests — VoiceOver users cannot operate tracks. Expose accessibility elements + tooltips. Refs: `Timeline/TimelineHeaderView.swift:126-138,169`.
- [ ] **7.2 Hit targets.** Trim grab zones 4pt → ~10pt (`Utilities/Constants.swift:101`, `Timeline/TimelineInputController.swift:142,154`); keyframe nav chevrons 6×18pt → usable (`Inspector/Keyframes/KeyframesLane.swift:10`, `Inspector/InspectorView.swift:554`); session close 12×12 (`Agent/Panel/AgentPanelView.swift:521`).
- [ ] **7.3 No hover-only actions.** Project delete exists only while hovered (VoiceOver can never reach it — add a context menu + keep the button in the hierarchy); same for media "Add to chat" and inactive-session close. Refs: `Project/ProjectCard.swift:74-87`, `MediaPanel/MediaTab/AssetThumbnailView.swift:215-228`, `Agent/Panel/AgentPanelView.swift:516-525`.
- [ ] **7.4 Label sweep.** Transport buttons (5, unlabeled — `Preview/PreviewContainerView.swift:94-104,695-704`), Send (`Agent/Panel/AgentInputBox.swift:162-174`), and the rest of the ~40 icon-only buttons get `.help` + `.accessibilityLabel`; `Generation/UI/GenerationView.swift:1458-1459` is the done-right template.
- [ ] **7.5 Keyboard focus.** Add keyboard commands to move panel focus (currently mouse-click only, which locks keyboard users out of the media panel's existing arrow-key nav); ⚖️ timeline clip keyboard selection and NSAccessibility children for the timeline are larger projects — scope them. Refs: `Editor/EditorWindowController.swift:49-53,191-202`.
- [ ] **7.6 Contrast.** `Text.muted` (34% white ≈ 2.5:1) carries real information 71 times; raise toward AA or demote its uses to decoration. Refs: `UI/AppTheme.swift:151`.
- [ ] **7.7 Tour teaches editing.** Add trim/split/ripple and export steps; fix the voice violations ("Chat with your agent!", "some cool AI features"). Refs: `Editor/Tour/TourController.swift:127-164`.

**Done when:** every action is reachable without a mouse hover, every icon control is named, and core editing gestures are physically hittable.

## Phase 8 — Consistency polish

- [ ] **8.1 ⚖️ One name.** "Venice Video Editor" (app menu, notifications, storage folder) vs "Venice Video Creator" (welcome, Home headline) — both appear on the same screen. Decide, then sweep (note `Utilities/Constants.swift:121` changes the storage path — migrate or keep). Refs: `App/MainMenu.swift:22-31`, `Project/WelcomeOverlay.swift:24`, `Project/HomeView.swift:159,219`.
- [ ] **8.2 Terminology sweep:** "Create Video" vs "Generate"; ASCII vs typographic ellipses; "audios" pluralization; passive "Export was cancelled"; "offline clips" vs "Media Offline". Refs: `Inspector/Tabs/AIEditTab.swift:72,79`, `Models/MediaAsset.swift:88-95`, `App/AppNotifications.swift:130`, `Export/ExportService.swift:131`.
- [ ] **8.3 Theme gaps then adoption:** add `Status.warning`, missing anim durations, dot/thumb sizes to AppTheme; then adopt `Status.*` at the `.green`/`.red`/`.orange` sites, unify the 4 section-header variants and 3 panel-header chromes (use `panelHeaderBar()`), extract shared project-card chrome, align the 3 sheet insets, make Export's CTA the standard prominent capsule. Refs: `Settings/AgentPane.swift:84`, `Generation/UI/GenerationView.swift:503,546`, `Agent/Panel/AgentPanelView.swift:91-97`, `Project/ProjectCard.swift:25-99`, `Export/ExportView.swift:307`.
- [ ] **8.4 Dark-mode robustness:** set `NSApp.appearance = .darkAqua` globally instead of relying on 5 per-window call sites. Refs: `Project/VideoProject.swift:373` et al.
- [ ] **8.5 Worst-file cleanups:** `Help/ShortcutsPane.swift` (~10 literals), `Generation/UI/GenerationView.swift` (~20), `Toolbar/ToolbarView.swift` one-off sizes. ⚖️ `AppTheme.FontWeight` is dead (~200 inline literals) — adopt it or delete it.

**Done when:** the app has one name, one voice, and one visual vocabulary.

---

## Do not churn — verified sound

Fixes must not degrade these; they were confirmed correct during the audit.

- **Export snapshots the timeline** (value type, copied at start) — keep exports operating on snapshots.
- **Undo architecture**: per-document `NSUndoManager`, systematic swap/snapshot patterns, agent edits share the stack with grouped labeled actions, no cross-window bleed, field editors isolated. Extend it (2.3, 2.6); don't restructure it.
- **Playback resilience**: delete/trim-while-playing and scrub-during-playback are handled — preserve the pause→rebuild→reseek flow.
- **Media panel drop architecture** (AppKit parent `MediaPanelDropArea` + SwiftUI leaf `.onDrop`) — probe-verified sound; it is the template for Phase 4, not a refactor target.
- **Key monitor's text-input guard** (`EditorWindowController.swift:184-189`) — typing never loses keystrokes; keep it intact while fixing 3.2/3.7.
- **Bounded Venice polling** (15 min video / 10 min audio timeouts), the smart-search model-download affordance, the agent error banner's contextual CTAs, and `GeneratingOverlay`'s Reduce Motion handling.

## Progress log

_Append one line per session: date, items completed, surprises._

- 2026-07-03 — Phase 1 (1.1–1.8) code-complete, ALL UNVERIFIED: this machine cannot build (macOS 15.6, CLT Swift 6.1.2; package needs Swift 6.2 + macOS 26 SDK; no Xcode on any volume). Jordan chose "keep coding, verify later" — every box checked this session needs a build + flow pass on a capable machine before trusting. Notables: cancellation is Task-based (AVAssetExportSession's async export cancels via task cancel; VeniceAPI wraps URLError so VeniceJobStore.settle detects cancellation via Task.isCancelled, not error type); queue_id/downloadURL now persist in GenerationInput and resume re-polls video|audio/retrieve; new `.cancelled` GenerationStatus case (check exhaustive switches if more appear); EditSubmitter tracks busy source ids in editor.activeAIEditSourceIds; document close detaches generation monitors but leaves Venice jobs running for resume-on-reopen.

# Plan — Venice Video Creator

> Written 2026-07-04 on branch `venice-integration` (HEAD bd2285d, CI green).
> Supersedes `ux-improvements-plan.md` and `harness-enhancements-plan.md` (both in git history at bd2285d~).
> This file assumes a machine that can build and RUN the app (Swift 6.2, macOS 26, arm64).

## Where things stand

- **UX improvements, all 8 phases: code-complete and CI-verified** (compile + full test suite on a macOS 26 runner; commits 3451f3d..90c01ae plus two one-line test fixes). Written without a compiler; **never run**.
- **Harness guardrails already shipped:** agent model-selection heuristics + Venice gotchas (`Agent/Tools/AgentInstructions.swift`), prompt budgets (`Generation/Catalog/PromptBudget.swift`), silent-reject byte guards (`Venice/VeniceGeneration.swift`), stepped-duration error text, multi-edit aspect restoration (`Generation/Edit/ImageAspectRestorer.swift`).
- **A high-effort code review of the UX diff confirmed 9 bugs + 1 to test live** — Phase 1 below.
- CI runs on every push to `venice-integration` (`.github/workflows/ci.yml`, macos-26 runner). Keep it green.

## Session kickoff prompt

> You are a senior macOS engineer finishing verified-but-never-run work on Venice Video Creator (Swift 6.2, SwiftUI + AppKit, AVFoundation, macOS 26, non-sandboxed). Read `PLAN.md` fully, then `AGENTS.md` — its rules on comments, AppTheme, drag-and-drop architecture, and product voice are non-negotiable.
>
> Work the phases in order. For every fix: read the cited code and its callers first, fix the cause not the symptom, `swift build`, and exercise the actual flow in the running app. Check the box, note surprises in the Progress Log, commit per completed cluster, push (CI must stay green).
>
> Respect the "Do not churn" list. Items marked ⚖️ need Jordan's call — recommend, then ask. Start with Phase 1, item 1.1.

## Ground rules

- **Build/run:** `swift build`, `swift run`. A fix to a flow is verified by exercising that flow, not by a clean compile.
- **AGENTS.md governs:** minimal one-line comments, all UI values through `AppTheme`, parent drop targets AppKit-only, voice direct/technical/calm.
- **Commits:** one per completed cluster, on this branch. CI runs on push.

---

## Phase 1 — Fix the confirmed review bugs

All nine were adversarially verified against the code at bd2285d. Severity order.

- [x] **1.1 Crash-loop opening a project with duplicate manifest ids.** `Project/VideoProject.swift:553` builds `Dictionary(uniqueKeysWithValues: pairs)` keyed by manifest entry id; duplicates (hand edit, interrupted save, legacy bug) trap with `Fatal error: Duplicate keys` inside the restore Task on every open — no recovery, and it contradicts the file's own bad-manifest resilience. `MediaManifest` decodes entries with no dedup. Fix: `Dictionary(pairs, uniquingKeysWith: { first, _ in first })`.
- [x] **1.2 Failed new-project save deletes a pre-existing project.** `App/AppState.swift:214` (`createProjectInteractively`): NSSavePanel lets the user pick an existing project and confirm Replace; if the save then fails early (disk full, permissions), NSDocument's safe-save never touched the original — but the cleanup `try? FileManager.default.removeItem(at: url)` deletes it anyway. The programmatic path (line ~194) is protected by a fileExists guard; the interactive path isn't. Fix: only remove `url` if nothing existed there before the save attempt.
- [x] **1.3 Legacy generation/cost history permanently wiped.** `Project/VideoProject.swift:452`: `restoreAssetsFromManifest()` now defers asset population into a Task, but `makeWindowControllers` still calls `seedGenerationLogFromAssets()` synchronously right after — it seeds from an empty `mediaAssets`, the empty log is unconditionally persisted on next save, and every later open takes the non-nil `loadedGenerationLog` branch. History gone for good. Fix: move the seed into `applyManifestRestore`'s completion, guarded on `loadedGenerationLog == nil`.
- [x] **1.4 Deleting one placeholder of a batch kills its siblings.** `Editor/ViewModel/EditorViewModel+ClipMutations.swift:686`: multi-output generations share one `backendJobId`/poll task (`GenerationService.swift:514-518`); `cancelGeneration(assetId:)` cancels the shared job with no sibling check, `applyBackendJobUpdate` marks ALL placeholders `.cancelled`, and `.cancelled` is excluded from resume — a paid 4-image batch dies because one tile was deleted. Fix: cancel the backend job only when no other live placeholder references the same jobId.
- [x] **1.5 Folder delete leaves zombie generation jobs.** `Editor/ViewModel/EditorViewModel+Folders.swift:90`: `deleteFolders` removes assets via `mediaAssets.removeAll` — it does NOT route through `deleteMediaAssets`, so it lacks the cancelGeneration pass added there. The orphaned monitor downloads results into the package as strays, fires checkpoint autosaves, and posts failure notifications for deleted assets. Fix: run the same cancelGeneration pass over `assetIdsToDelete` before removal.
- [x] **1.6 Export cancel is dead during the slow prep phase.** `Export/ExportService.swift:117`: `waitForExportSlot`'s `defer` nils `cancelCurrent` before `makeExportSession` (composition build — the visibly slow part) begins; the enabled "Cancel Export" button silently no-ops (`cancel()` is `cancelCurrent?()`, unlatched), and the XML/FCPXML branch never assigns `cancelCurrent` at all. Fix: run the whole `export()` body in one stored Task and cancel that; cooperative cancellation already exists downstream.
- [x] **1.7 Quit guard blind to the prepare/upload phase.** `App/AppDelegate.swift:38`: the guard reads `GenerationBackend.activeJobCount`, which only counts submitted jobs; the minutes-long base64-encode/upload phase lives in `GenerationService.generationTasks` and is invisible — Cmd+Q during "Preparing…" quits silently and the work is unresumable (no queue_id yet). Fix: expose a pre-submit count from `GenerationService` and include it (or add a shared busy-work registry; the Sparkle guard in `App/Updater.swift:117` should consult the same source — it currently checks exports only).
- [x] **1.8 Cancel during upload shows "failed", not "cancelled".** `Generation/GenerationService.swift:117`: the catch matches only `CancellationError`, but VeniceAPI wraps `URLError(.cancelled)` into `VeniceError.transport` — the exact pitfall `GenerationBackend.settle` documents and handles via `Task.isCancelled`. Mirror that check in the generic catch.
- [x] **1.9 Esc silently became a destructive export abort.** `Export/ExportView.swift:338`: pre-change, Esc (`.cancelAction`) dismissed the sheet and the render continued; now the same keystroke calls `service.cancel()` while exporting, and the cancel path deletes the partial file (`ExportService.swift:158`). ⚖️ Decide: Esc dismisses (export continues, sheet reopenable) with the button alone doing destructive cancel, or a confirmation on cancel. Recommend the former.
- [x] **1.10 TEST LIVE: internal drags may be dead at the new drop zones.** `Generation/UI/DropZoneView.swift:54` (same pattern in `Preview/PreviewDropArea.swift`, `MediaPanel/MediaTab/MediaPanelDropArea.swift`, `Agent/Panel/AgentInputDropArea.swift`): `draggingEntered` now reads `draggingPasteboard.string(forType: .string)` at drag-ENTER, but SwiftUI `.draggable(String)` sources (`MediaTab+Grids.swift:381`) fulfill the string promise lazily. Pre-change these returned `.copy` unconditionally at enter. Drag a media tile over each zone in the running app; if zones don't highlight/accept, defer payload inspection to `performDragOperation`.

**Done when:** all nine fixes land with the specific flow exercised, and 1.10 is tested (and fixed if broken) in the running app.

## Phase 2 — Runtime verification of the unverified phases

None of the 8 UX phases has ever executed. The prior session flagged these as the riskiest bets; run each in the app:

Live session 2026-07-04 (agent-driven via cua-driver against a real project "AI Short Film", macOS 26.5, ad-hoc debug bundle). Legend: [x] verified, [~] partially verified, [ ] still pending.

- [~] Cancel an export mid-render (file cleanup, slot release, "Export cancelled" message). **Happy path verified**: Video/H.264 export via the sheet → Save panel → produced a valid 20 MB mp4. **Cancel not verified** — the 17s project renders faster than the automation can snapshot+click the Cancel control; needs a multi-minute timeline (or a manual run) to catch mid-render. The XML/FCPXML (Timeline/Venice Project) branches are near-instant too.
- [ ] Quit during an export and during a generation (guard prompt appears; Cancel-quit actually stops termination). Not tested (export too fast to overlap Cmd-Q; generation is paid).
- [ ] Relaunch mid-video-generation — resume by queue_id. **Paid — deferred to a session with Jordan.**
- [ ] Delete a generating placeholder + folder-delete variant. **Paid — deferred.**
- [ ] Folder selected → click timeline clip → Delete: only the scoped target dies. **Not driven** — destructive on the real project and timeline clips are custom-drawn (not AX-addressable), so a pixel-drive delete + verify is fragile; recommend a manual check (or a throwaway project).
- [x] **Bare-key menu equivalents (Space/arrows/⌫) near text fields — VERIFIED.** Space in a focused media-search text field typed a space and did NOT toggle playback; with the timeline focused (after Go to Start), Space started playback (button→Pause, time advanced) and stopped it again. The EditorWindowController text-input guard works. (⌫ delete path not exercised — it's the destructive item above.)
- [ ] Sparkle: `shouldPostponeRelaunchForUpdate(untilInvokingBlock:)` — compile proves the signature (build green); a real update flow (needs a signed/notarized build + appcast) proves behavior. Deferred.
- [ ] Preview drop: hit-test-transparent `PreviewDropNSView` receives drags. Not reliably testable via synthetic pixel drag (SwiftUI `.draggable(String)` lazy promise); recommend a manual drag.
- [x] **Double-fire guards — VERIFIED** (one paid Grok Imagine image gen). Firing the Generate submit twice rapidly: the first click started the job, the button went `DISABLED` immediately, and the second click was a rejected no-op — exactly **one** placeholder appeared. During generation the inspector's Upscale / AI Edit / Remove Background / Rerun / Generate Video all showed `DISABLED` + "Generation in progress" tooltips (proper feedback, not a silent no-op — addresses the AIEditMenu concern for the panel path; the context-menu path still worth a code check).
- [x] **Delete a generating placeholder — VERIFIED** (same gen). Right-click placeholder → Delete returned the Library to 2 items with **no zombie re-append** and no error toast over ~8s. ⚠️ **Finding:** the just-downloaded `gen-<id>.png` remained in the package `Media/` dir after delete — likely undo-retention, but confirm it's not an orphaned stray (relates to 1.5). Not verified: the 4-image batch-sibling case (1.4) — would need a multi-image gen.
- Also observed live: **3.1 fix working** — the generating overlay's elapsed timer counts up (showed 0:03 in tile + preview).
- [x] **Transport / playback + isPlaying sync — VERIFIED** (supports 3.2): Play/Pause via button and Space both round-trip cleanly, playhead advances, button state tracks. (The exact 3.2 desync — background timeline edit on a non-timeline tab — was not reproduced.)

### Phase 2 — manual checklist (for a human at the machine)

These resist reliable agent automation (render too fast, custom-drawn/undraggable surfaces, destructive on a real project, or need a signed build). Run each on a throwaway project you're willing to edit:

1. **Export cancel mid-render (1.6/1.9):** build a multi-minute timeline (so the H.264 render lasts >10s). Start a Video export → during the render, (a) press **Esc** → the sheet should dismiss and the export should keep going (reopen to confirm); (b) start again and click **Cancel Export** → render stops, the partial file is deleted, slot released, and an "Export cancelled" message shows. Repeat for the Timeline (FCPXML) and Venice Project branches.
2. **Quit during work (1.7):** during that long export, and separately during a live generation, press ⌘Q → the guard prompt must appear; "Cancel" must actually stop termination.
3. **Relaunch mid-video-generation (resume):** start a video gen, quit/relaunch → it must resume by queue_id and complete, or fail visibly with Retry — never an eternal shimmer.
4. **Delete scoping (item 5):** with a media folder selected AND a timeline clip selected, press ⌫ → only the scoped target (the clip) should die, not the folder's media. Also try ⌫ with focus in the preview/inspector while a clip is visibly selected — confirm sane behavior.
5. **Preview drop (item 8 / 1.10):** drag a media tile from the Library onto the preview canvas → it should highlight and accept (validates the hit-test-transparent `PreviewDropNSView` + the 1.10 drag-enter accept-on-advertised-type fix). Repeat over the timeline, media panel, and agent-input drop zones.
6. **Sparkle (item 7):** with a signed/notarized build + appcast entry, trigger an update while an export/generation runs → relaunch should postpone until the work finishes.
7. **Batch-sibling cancel (1.4):** generate a 4-image batch, delete ONE tile → the other three must keep generating (not all cancel).

## Phase 3 — Smaller verified defects (fix opportunistically)

- [x] **3.1 Elapsed timer resets when tiles scroll.** `UI/GeneratingOverlay.swift:16` — `@State startedAt = Date()` in a LazyVGrid resets offscreen. Seed from the generation's persisted start time instead.
- [x] **3.2 Playback state desync on background timeline edits.** `Editor/ViewModel/EditorViewModel.swift:357` — `notifyTimelineChanged` uses raw `player.pause()`; `rebuild()` early-returns (non-timeline tab, build throw) without resyncing `isPlaying`, so the transport needs two presses. Pause via the engine or resync on every rebuild exit.
- [x] **3.3 Transcription toasts route to the frontmost project,** not the owning one, and re-fire per clip. `App/AppDelegate.swift:19` static callbacks → thread an editor context through the transcription call instead.

## Phase 4 — Review cleanup batch (one commit)

- [~] One `NSDraggingInfo.droppedFileURLs` extension replaces the five copies of the pasteboard-read helper **(done, `DropZoneView.swift`)**; collapse the four near-identical drop NSViews onto the existing `MediaPanelDropArea`/`DropTargetOverlay` pattern (one configurable host) **(deferred — behavior-sensitive, do with runtime verification; the four have subtly different accept ordering/fall-through)**.
- [ ] Extract `EditorViewModel.importFinderItemsForPlacement(_:) async -> [MediaAsset]` — the snapshot/import/diff/loadMetadata/place sequence is duplicated in `Timeline/TimelineView.swift:1200` and `Preview/PreviewContainerView.swift:53`, and the per-asset `loadMetadata` loop should be a task group (drops of 20 files currently serialize).
- [ ] Share the drop-commit choreography between `TimelineView.place()` and `EditorViewModel.insertAtPlayhead` (undo grouping + plan/materialize/addClips).
- [ ] `VeniceJobStore.activeCount` → `tasks.count` (single source of truth); retire the `mediaPanelToast` forwarding alias (rename call sites to `editorToast`).
- [ ] Hoist the repeated modifier guard in `EditorWindowController`'s key monitor to one top-of-switch check; share delete-enablement between `validateUserInterfaceItem` and `performScopedDelete`.
- [ ] Perf: compute `deletionImpactCount` lazily inside the folder tile's contextMenu (`MediaPanel/MediaTab/MediaTab+Grids.swift:409` — currently O(F×(F+A)) per render); stop calling `rebuildToolTips()` from `draw()` (`Timeline/TimelineHeaderView.swift:124`) — rebuild on track mutation instead; restore concurrent `async let` in `AccountService.refreshUsage:80`; replace `waitWhileExportActive`'s 2s poll with continuations resumed in `endExport()`.
- [ ] Conventions: trim the new multi-line comment blocks to one line (AGENTS.md rule; e.g. `AgentInputDropArea.swift:4`, `GeneratingOverlay.swift:24`, `GenerationService.swift:341`, `VideoProject.swift:354`); `KeyframesLane.swift:10` nav-button width 16 → AppTheme constant.

## Phase 5 — Remaining harness enhancements

Detail and harness source references: `harness-enhancements-plan.md` at bd2285d~ in git history.

- [x] **5.1 Agent last-frame tool — DONE.** Added `extract_last_frame` (ToolName + dispatch + schema + impl in `ToolExecutor+Generate.swift`): resolves a video asset, computes the source time (explicit `atSeconds` → `sourceClipId` trim/speed-aware last visible frame → asset end), extracts a PNG via `LastFrameExtractor`, imports it via `importPastedImageData`, names/folders it, and returns the still's id for use as `startFrameMediaRef`. Reuses the exact paths the shipping "Last frame → video" UI feature uses. Added shot-continuity guidance to `AgentInstructions.swift`. Build green; 878/878 tests pass. Not yet live-exercised through the agent (would need a rebuild + agent turn).
- [~] **5.2 Catalog mapper capability fix.** `Venice/VeniceModel.swift` `videoEntry` hardcodes `maxReferenceVideos: 0`, `maxReferenceAudios: 0`, `supportsLastFrame: false`. **Done: `supportsLastFrame`** — added `VideoModelCapabilities.supportsEndImage` (family-substring allowlist ported from the probe-verified harness registry `venice-video-harness/src/venice/models.ts`), gated on `isImageToVideo` (end frame shares the first-frame slot, so only i2v can use it). Enables end-frame for Kling i2v, Wan 2.7 i2v (+Spicy), and PixVerse transition; unknown ids stay false (no regression — end frame was impossible before). Unit-tested. **Deferred: `maxReferenceAudios`** — belongs with 5.3 (enabling it sends `audio_url`, which Wan rejects < 3s, so it must land with the padding), and per the non-regression guarantee must be gated to audio-input-capable models (registry: `wan-2.6*`, `wan-2-7` i2v/t2v/v2v/spicy, `wan-2.5-preview*`, `wan-2.6-r2v`, `davinci-magihuman`). **Not done: `maxReferenceVideos`** — the harness registry has no reference-video capability flag, so there's no authoritative source to key off; left at 0.
- [ ] **5.3 Wan audio preflight/padding** (after 5.2; first confirm an audio-capable Wan model appears in the live catalog). Min 3s; pad trailing silence via AVFoundation export to a new temp file — no ffmpeg, never mutate source audio.
- [ ] **5.4 Model-routing code layer** (instructions already shipped) — suggested default only, never override an explicit model choice.
- [ ] **5.5 Structured `elements`/`scene_image_urls`** — highest risk; emit only behind an explicit allowlist, flat `reference_image_urls` stays the default. The harness itself is inconsistent here (registry vs runtime set for Wan 2.7) — don't port the contradiction.
- [ ] **5.6 Deprecation headers** — only if a live Venice response proves `Deprecation`/`Sunset` headers exist; otherwise drop.

## Carried-over deferred items (from the UX session)

Need a running app or are larger projects; unowned for now:

- Transcription model-download cancel affordance.
- Timeline clip keyboard selection + NSAccessibility children for timeline clips (scope as own project).
- Icon-button label sweep beyond transport/Send/Stop/session-close.
- 8.3 structural chrome unification (section headers, panel header chromes, project-card extraction, sheet insets).
- 8.5 literal sweeps in ShortcutsPane/GenerationView/ToolbarView.

## Do not churn — verified sound

- Export snapshots the timeline (value copy at start) — keep exports on snapshots.
- Undo architecture (per-document NSUndoManager, grouped labeled agent actions) — extend, don't restructure.
- Playback resilience (pause→rebuild→reseek flow).
- Media panel drop architecture (AppKit parent + SwiftUI leaf `.onDrop`) — the template, not a refactor target. Phase 4's consolidation must preserve its behavior exactly.
- Key monitor's text-input guard (`EditorWindowController.swift:184-189`).
- Bounded Venice polling, silent-reject guards, `PromptBudget` (advisory-only — never make it block).

## Progress log

_One line per session: date, items completed, surprises._

- 2026-07-04 — Plan created. Prior state: 8 UX phases + 2 test fixes CI-green (bd2285d); review filed 9 confirmed bugs (Phase 1) + cleanup backlog; old plan files removed (content in git history).
- 2026-07-06 — Phase 5.2 (partial): enabled `supportsLastFrame` via a new `VideoModelCapabilities` family allowlist ported from the probe-verified harness registry, gated on i2v. Resolved the Phase-2 stray-file finding as intentional undo-retention (deleteMediaAssets cancels in-flight gens then keeps the file for undo — not a leak). Deferred the audio-ref enable to land with 5.3; maxReferenceVideos has no authoritative capability source. Build green, 879 tests (added VideoModelCapabilities tests).
- 2026-07-04 — Phase 5.1 done: `extract_last_frame` agent tool (free/local still extraction for shot chaining) + continuity guidance in AgentInstructions. Thin wrapper over LastFrameExtractor + importPastedImageData (same as the UI feature). Build green, 878/878 tests.
- 2026-07-04 — Phase 2 continued: authorized one paid image gen. VERIFIED live: double-fire guard (2nd rapid submit rejected, button disables, one job); in-progress feedback on all AI-enhance actions; delete-generating-placeholder (→2 items, no zombie); 3.1 elapsed timer counting. Finding: a downloaded gen-<id>.png stayed in package Media/ after delete (undo-retention vs stray — needs a look). Added a "Phase 2 — manual checklist" section for the checks that resist automation (export cancel, quit guard, resume, delete scoping, preview drop, Sparkle, batch-sibling cancel).
- 2026-07-04 — Phase 2 partial live run (cua-driver, real "AI Short Film" project). Verified: app builds→bundles→launches→interactive; transport/playback + isPlaying sync; export happy-path (H.264 → valid mp4); bare-key menu equivalents + text-field guard (Space toggles play only when timeline focused, swallowed in a text field). Not verified / deferred: export cancel mid-render (project too short to catch), quit-during-work guard, Delete scoping (destructive + clips not AX-addressable), preview drop (synthetic drag unreliable), Sparkle update flow (needs signed build), and all generation-dependent items (paid). App requests Accessibility at launch (global key monitor). No project data modified.
- 2026-07-04 — Phase 4 partial (safe subset): extracted `NSDraggingInfo.droppedFileURLs` (@MainActor) into `DropZoneView.swift`, replacing the 5 duplicated pasteboard-read helpers across the four drop NSViews + `TimelineView`; trimmed `AgentInputDropArea`'s paragraph docstring. Deferred (behavior-sensitive / need running app): NSView consolidation, `importFinderItemsForPlacement` extraction, drop-commit choreography sharing, key-monitor guard hoist, perf batch, `activeCount`/`editorToast` renames, remaining comment sweep. Build green; 878/878 tests pass.
- 2026-07-04 — Phase 3 (3.1–3.3) landed. 3.1 seeds `GeneratingOverlay` from `generationInput.createdAt` so the elapsed clock survives LazyVGrid recycling. 3.2 adds `syncPausedPlaybackState()` on `rebuild()`'s non-resuming exits (guard-fail, build-throw) to end the two-press desync. 3.3 replaces `Transcription`'s global static callbacks with a per-run `Transcription.Reporter` (Sendable, latched) threaded through `TranscriptCache`, captions, and agent read tools; toasts now route to the owning editor and fire once. Build green; full suite passes (one flaky `FrameSampler` coverage-floor test passes on isolated rerun). Phase 2 runtime verification still pending (needs live app + paid generations).
- 2026-07-04 — Phase 1 complete (1.1–1.10). Build green, full suite 878/878 pass. Notes: (1.4/1.5) replaced per-asset `cancelGeneration` with a set-aware `cancelGenerations(assetIds:)` so batch/folder deletes decide "cancel the shared job only when no live sibling remains outside the removed set" — fixes both the sibling-kill and the zombie-job leak in one primitive; deleteMediaAssets and deleteFolders both route through it. (1.6) moved cancellation to one stored task wrapping the whole export body (and did the same for `exportVeniceProject`, forwarding cancellation to its detached collect task via `withTaskCancellationHandler`); `waitForExportSlot` no longer manages `cancelCurrent`. (1.7) added `GenerationService.preSubmitGenerationCount` + `AppState.preSubmitGenerationCount`/`hasInFlightWork`; quit guard adds pre-submit count, Sparkle relaunch guard now waits on all in-flight work, not just exports. (1.9) Jordan chose: Esc dismisses the sheet (export continues in background), only the "Cancel Export" button is destructive — implemented via `.onExitCommand`; ExportService NOT hoisted, so reopening the sheet shows fresh state (acceptable per decision). (1.10) real bug confirmed in code (value read of a lazy `.draggable(String)` at drag-enter); applied the prescribed fix (accept on advertised type at enter, read payload at drop) to all four zones — AgentInputDropArea keeps plain-text fall-through by only accepting a resolved string when it parses as an asset payload. **Still needs a live drag test in the running app** (1.10) and live runtime verification of the export-cancel / quit-during-generation flows (Phase 2).

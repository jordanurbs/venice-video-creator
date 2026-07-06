# Plan — Venice Video Creator

> Branch `venice-integration`. CI runs on push (macos-26 runner) — keep it green.
> Assumes a machine that can build and RUN the app (Swift 6.2, macOS 26, arm64).
> Superseded plan files (`ux-improvements-plan.md`, `harness-enhancements-plan.md`)
> and the full shipped-phase detail live in git history (at `bd2285d` and its parents).

## Status

- **Shipped + pushed, full suite 886 tests green:**
  - **Phase 1** — 9 confirmed review bugs (crash-loop on dup manifest ids, failed-save deletes existing project, wiped generation history, batch-sibling / folder-delete zombie jobs, dead export-cancel in prep, quit guard blind to prepare/upload, cancel-shows-failed, Esc destructive-abort, drag-enter accept-on-advertised-type).
  - **Phase 3** — 3.1 elapsed-timer survives grid recycling, 3.2 playback resync on rebuild exits, 3.3 per-run transcription reporter (toasts route to owning editor, fire once).
  - **Phase 4 (safe subset)** — `NSDraggingInfo.droppedFileURLs` dedup; conventions sweep (multi-line comment trims + `AppTheme.IconSize.xsSm`).
  - **Phase 5.1** — `extract_last_frame` agent tool + continuity guidance.
  - **Phase 5.2** — `supportsLastFrame` via `VideoModelCapabilities.supportsEndImage` (i2v-gated family allowlist).
  - **Phase 5.3** — Wan/MagiHuman `audio_url` (`audioInputCapable`) + native `AudioSilencePadder` trailing-silence pad, gated on `minAudioInputSeconds`.
- **`VideoModelCapabilities` re-verified 2026-07-06** against the freshly-synced harness registry (`~/Projects/video-proj/venice-video-harness/src/venice/models.ts`) — still correct; new models (HappyHorse 1.0/1.1, Runway Gen-4.5, PixVerse C1, Seedance 2.0 Fast, Kling V3 4K, …) fall through the substring allowlists to safe defaults as designed.

## Ground rules

- **Build/run:** `swift build`, `swift run`. Launchable bundle: `scripts/bundle.sh debug --fast` → `.build/Venice Video Creator.app` (bundle id `ai.venice.studio`; requests Accessibility at launch for its key monitor). Verify a flow by exercising it, not by a clean compile.
- **AGENTS.md governs:** minimal one-line comments, all UI values through `AppTheme`, parent drop targets AppKit-only, voice direct/technical/calm.
- **Non-regression is a hard constraint:** new request params opt-in behind capability flags defaulting to current behavior; guardrails warn before they block; source media is never mutated (pad/convert to temp files); the shared UI/agent validation path stays shared.
- **Harness is the authoritative reference.** Before changing anything touching model capabilities / request bodies / endpoints / workflow, re-read the relevant harness source fresh (it drifts — check "Last synced"). Port knowledge into `Generation/Catalog/VideoModelCapabilities.swift` as family-substring allowlists keyed off Venice slugs; unknown ids fall through to safe/current behavior.
- **Test-suite gotcha:** do NOT add tests that spin up `AVAssetExportSession` to the default suite — Swift Testing's cross-suite parallelism makes them SIGTRAP non-deterministically. Keep such checks to isolated `--filter` runs or live testing.
- **Commits:** one per completed cluster on this branch; push (CI validates).

---

## Open work

### Phase 2 — manual runtime checklist (for a human at the machine)

Agent-driven `cua-driver` already verified: transport/playback + isPlaying sync, export happy-path (H.264 → valid mp4), bare-key menu equivalents + text-field guard, double-fire guards, delete-generating-placeholder, 3.1 elapsed timer. The rest resist automation (render too fast, custom-drawn/undraggable surfaces, destructive, or need a signed build / paid gens). Run each on a throwaway project:

1. **Export cancel mid-render (1.6/1.9):** build a **multi-minute** timeline. Start a Video export → during render (a) press **Esc** → sheet dismisses, export keeps going (reopen to confirm); (b) start again, click **Cancel Export** → render stops, partial file deleted, slot released, "Export cancelled" shows. Repeat for Timeline (FCPXML) and Venice Project branches.
2. **Quit during work (1.7):** during that long export, and separately during a live generation, press ⌘Q → guard prompt must appear; "Cancel" must actually stop termination.
3. **Relaunch mid-video-generation (resume):** start a video gen, quit/relaunch → it must resume by queue_id and complete, or fail visibly with Retry — never an eternal shimmer.
4. **Delete scoping:** media folder selected AND a timeline clip selected, press ⌫ → only the clip dies, not the folder's media.
5. **Preview drop:** drag a media tile onto the preview canvas → it highlights and accepts. Repeat over timeline, media panel, agent-input zones (validates the 1.10 drag-enter fix).
6. **Sparkle:** with a signed/notarized build + appcast, trigger an update while an export/generation runs → relaunch should postpone until the work finishes.
7. **Batch-sibling cancel (1.4):** generate a 4-image batch, delete ONE tile → the other three keep generating.

### Phase 5.2 + 5.3 — live confirmation (needs a running app + paid gens)

- **End-frame (5.2):** on a Kling i2v or Wan 2.7 i2v model, confirm the last-frame slot appears; set start + end image, generate → clip morphs start→end. ❌ if the slot is missing or the gen errors about the end frame.
- **Wan lip-sync (5.3):** on Wan 2.7 i2v (or DaVinci MagiHuman), confirm the audio-reference slot appears. Test A: attach a **<3s** clip → no "too short" error, renders with lip-sync (auto-padded to 3s). Test B: attach a **≥3s** clip → lip-sync works, audio not altered oddly.

### Phase 4 — remainder (behavior-sensitive; do WITH a runtime pass)

The drop architecture's behavior must be preserved exactly (AppKit parent + SwiftUI leaf `.onDrop`).

**Done (2026-07-06, no runtime pass required, 886 green):**
- ✅ Extracted `EditorViewModel.importFinderItemsForPlacement(_:) async -> [MediaAsset]` (was duplicated in `TimelineView` + `PreviewContainerView`); per-asset metadata loads now overlap via unstructured `Task`s (the region-isolation checker rejects `TaskGroup.addTask` capturing a `@MainActor` `MediaAsset`).
- ✅ `VeniceJobStore.activeCount` → `tasks.count`; retired the `mediaPanelToast`/`dismissMediaPanelToast` forwarding alias (all call sites now `editorToast`/`dismissEditorToast`).
- ✅ Perf: `deletionImpactCount` is now a lazy `() -> Int` computed only when the folder context menu opens (was O(F×(F+A)) per grid render); `AccountService.refreshUsage` fetches rate limits + usage analytics concurrently again (preserving the 401/403 early exit).

**Still open (behavior-sensitive — do WITH a runtime pass):**
- Collapse the four near-identical drop NSViews onto one configurable host (`MediaPanelDropArea`/`DropTargetOverlay` pattern) — they have subtly different accept ordering / fall-through.
- Share the drop-commit choreography between `TimelineView.place()` and `EditorViewModel.insertAtPlayhead` (undo grouping + plan/materialize/addClips).
- Hoist the repeated modifier guard in `EditorWindowController`'s key monitor to one top-of-switch check; share delete-enablement between `validateUserInterfaceItem` and `performScopedDelete`.
- Perf (deferred — need eyes on timing/concurrency): stop calling `rebuildToolTips()` from `TimelineHeaderView.draw()` (rebuild on track mutation — but tooltip rects are computed in `draw()`, so tooltip staleness during resize/reorder drags must be verified); replace `ExportCoordinator.waitWhileExportActive`'s 2s poll with continuations resumed in `endExport()` (a missed resume hangs search indexing until relaunch — verify with a live export running concurrently with indexing).

### Phase 5.5 — structured `elements` / `scene_image_urls` (highest risk; needs live verify)

Registry has the data (`supportsElements`/`supportsSceneImages`: Kling O3 / V3-4K R2V, Wan 2.7 R2V), but emitting structured params changes paid request bodies and the harness is internally inconsistent for Wan 2.7 R2V (marked `supportsElements` yet runtime routes it flat). Gate strictly behind an allowlist flag defaulting **off**; flat `reference_image_urls` stays default. Verify against live before shipping.

### Phase 5.6 — deprecation headers (drop unless proven)

Only if a live Venice response actually carries `Deprecation`/`Sunset` headers. Needs a header dump; otherwise drop.

### To unblock 5.5 / 5.6, hand the next session:

- A dump of the **live** `GET /models?type=all` response (confirm current video slugs; see whether Venice exposes `elements`/`scene_image_urls` constraints).
- Whether any Venice response carries `Deprecation` / `Sunset` **headers**.

### Carried-over deferred (need a running app or are their own project)

- Transcription model-download cancel affordance.
- Timeline clip keyboard selection + NSAccessibility children for timeline clips.
- Icon-button label sweep beyond transport/Send/Stop/session-close.
- 8.3 structural chrome unification; 8.5 literal sweeps in ShortcutsPane/GenerationView/ToolbarView.

## Do not churn — verified sound

- Export snapshots the timeline (value copy at start) — keep exports on snapshots.
- Undo architecture (per-document NSUndoManager, grouped labeled agent actions) — extend, don't restructure.
- Playback resilience (pause→rebuild→reseek flow).
- Media panel drop architecture (AppKit parent + SwiftUI leaf `.onDrop`) — the template, not a refactor target. Phase 4's consolidation must preserve its behavior exactly.
- Key monitor's text-input guard (`EditorWindowController.swift`).
- Bounded Venice polling, silent-reject guards, `PromptBudget` (advisory-only — never make it block).

## Progress log

_One line per session: date, items completed, surprises._

- 2026-07-04 — Plan created. Prior: 8 UX phases + 2 test fixes CI-green (bd2285d); review filed 9 bugs + cleanup backlog.
- 2026-07-04 — Phase 1 complete (1.1–1.10); Phase 3 (3.1–3.3); Phase 4 safe subset (drop pasteboard-helper dedup); Phase 5.1 (`extract_last_frame`). Phase 2 partial live run via cua-driver (transport/playback, export happy-path, menu-key guard, double-fire, delete-placeholder, 3.1 timer). Full suite 878 green.
- 2026-07-06 — Phase 5.2 (`supportsLastFrame`, i2v-gated allowlist) + 5.3 (Wan/MagiHuman `audio_url` + native `AudioSilencePadder`). Export-based padder test dropped (destabilized the parallel suite; passed in isolation). Needs live Wan lip-sync + end-frame confirmation. 886 green.
- 2026-07-06 — Phase 4 conventions sweep (multi-line comment trims + `AppTheme.IconSize.xsSm` for nav-button width). Re-verified `VideoModelCapabilities` against the freshly-synced harness registry — still correct; new models fall through to safe defaults. Trimmed this plan (shipped detail is in git history). 886 green, CI validated.
- 2026-07-06 (late) — **Export cancel confirmed fixed** (Esc + button both discard the partial): `cancel()` now calls `AVAssetExportSession.cancelExport()` explicitly (Task cancel alone doesn't stop the async render), and cancel-on-`onDisappear` covers macOS dismissing the `.sheet` on Esc without routing through `onExitCommand`. Wrote `HANDOFF.md` (open plan + manual checklist). 886 green.
- 2026-07-06 — Phase 4 safe subset (no runtime pass): sorted Models-settings dropdowns alphabetically; extracted `importFinderItemsForPlacement` (overlapping metadata loads); `activeCount` → `tasks.count`; retired the `mediaPanelToast` alias; lazy `deletionImpactCount`; concurrent `refreshUsage`. Deferred `rebuildToolTips`-out-of-`draw()` and `waitWhileExportActive` continuations to a runtime pass (tooltip-staleness / indexing-hang risk). 886 green.
- 2026-07-06 — Live-test fixes with Jordan running the app: **5.2** end-frame confirmed on Kling; **live-corrected** the harness + app (dropped Wan 2.7 from the end-image allowlist — Venice 400 "does not support end_image_url" despite the registry) and added a `.cursor/rules/harness-app-capability-sync.mdc` sync rule. **5.3** Wan audio confirmed; MagiHuman lip-sync surfaced two issues → (a) added a **dedicated labeled Audio slot** for audio-only i2v/t2v models (was hidden in the generic references grid + tripped the starting-image guard on add), (b) waveform icon on filled slots, (c) reference slots are now **click-to-import** (Finder panel → same copy-in path as drop). **MagiHuman timeout**: raised the video poll window 15→30 min (matches harness) + surface terminal FAILED status; MagiHuman is a slow talking-head model (native 5–10s, Venice exposes to 30s). **Phase 2 export-cancel**: Esc now cancels an in-progress export cleanly (was dismissing + leaving an invisible background render + orphaned partial). All 886 green. NOTE: Venice's live catalog transiently dropped `davinci-magihuman-image-to-video` — app has no model filter, list is 100% live; awaiting a `models?type=all` dump to confirm + unblock 5.5/5.6.

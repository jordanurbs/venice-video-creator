# Session Handoff — Venice Video Creator

> Updated 2026-07-06. Branch `venice-integration`, CI green, full suite **886 tests**.
> Read `PLAN.md` for the full open-work plan and `AGENTS.md` for the non-negotiable rules
> (one-line comments, `AppTheme` for all UI values, AppKit-parent/SwiftUI-leaf drop architecture,
> terse Apple-HIG voice). The harness at `~/Projects/video-proj/venice-video-harness/` is the
> authoritative model reference — re-read `src/venice/models.ts` fresh each session (it drifts).

## Shipped this session (all pushed, CI-green)

- **5.2 end-frame — confirmed live on Kling.** Live-corrected the harness **and** app: dropped the
  Wan 2.7 family from the end-image allowlist because Venice's live queue returns 400
  "does not support end_image_url" despite the registry (`afe53ec`, harness commit `5f98fa3`).
- **Added `.cursor/rules/harness-app-capability-sync.mdc`** (`efef8ff`) — codifies that the harness
  `VIDEO_MODELS` registry and the app's `VideoModelCapabilities` allowlists must change together,
  live-API-beats-harness, and unknown ids fall through to safe defaults.
- **5.3 Wan audio — confirmed live.** For audio-only i2v/t2v models (Wan 2.7, MagiHuman): added a
  **dedicated labeled Audio slot** (was hidden in the generic references grid and tripped the
  starting-image guard on add) (`d6ccfbe`), a **waveform icon** on filled slots (`108107e`), and
  **click-to-import** on every reference slot — clicking opens a Finder panel and copies the file in
  via the same path as a drop (`a415bd9`).
- **MagiHuman timeout fix** (`0128aea`) — raised the client video-poll window 15→30 min (matches the
  harness) and now surface a terminal `FAILED` status immediately. MagiHuman is a slow talking-head
  model (native 5–10s; Venice exposes up to 30s).
- **Export cancel fully fixed + confirmed** — Esc during an active export now cancels cleanly like the
  Cancel Export button: `cancel()` calls `AVAssetExportSession.cancelExport()` explicitly (Task
  cancellation alone doesn't stop the async render), and cancel-on-`onDisappear` guarantees a
  sheet-dismiss (macOS handles Esc on `.sheet` itself, bypassing `onExitCommand`) aborts the render
  and deletes the partial file (`3b2a548`, `2bf2a38`, `578319b`).
- Phase 4 conventions sweep + `AppTheme.IconSize.xsSm`; PLAN.md trimmed (earlier this session).

## What's left in the plan

### Live-gated build items (need the data below)
- **5.5 structured `elements` / `scene_image_urls`** — highest risk. Registry has the data (Kling O3 /
  V3-4K R2V, Wan 2.7 R2V) but emitting structured params changes paid bodies and the harness is
  internally inconsistent for Wan 2.7 R2V. Gate strictly behind an allowlist flag defaulting **off**;
  flat `reference_image_urls` stays default. Verify live before shipping.
- **5.6 deprecation headers** — only if a live Venice response actually carries `Deprecation`/`Sunset`
  headers. Drop unless proven.

### Data to hand the next session (unblocks the above)
Run these with your Venice key (base `https://api.venice.ai/api/v1`):
```bash
# 1. Current video slugs + constraints (feeds 5.5)
curl -s "https://api.venice.ai/api/v1/models?type=all" -H "Authorization: Bearer $VENICE_API_KEY" \
  | jq '.data[] | select(.type=="video") | {id, constraints: .model_spec.constraints}'
# 2. Response headers (feeds 5.6)
curl -s -D - -o /dev/null "https://api.venice.ai/api/v1/models?type=all" -H "Authorization: Bearer $VENICE_API_KEY"
```
> NOTE: `davinci-magihuman-image-to-video` was **removed from Venice's live catalog** (confirmed gone
> 2026-07-06). Its entry was dropped from the harness registry and the matching `magihuman` branches
> from the app's `VideoModelCapabilities` in the same change. Restore both if Venice re-adds it.

### Phase 4 remainder — ✅ COMPLETE (code done + 886 green; run the checklist below to confirm behavior)
Preserve the drop architecture exactly (AppKit parent + SwiftUI leaf `.onDrop`).

Earlier (no runtime pass): extracted `importFinderItemsForPlacement`, `activeCount` → `tasks.count`,
retired the `mediaPanelToast` alias, lazy `deletionImpactCount`, concurrent `refreshUsage`,
alphabetical Models dropdowns, `hasDeletableSelection`.

2026-07-07 (behavior-sensitive — verify at runtime):
- Four native drop NSViews collapsed onto one closure-driven `NativeDropHostingView` (accept/perform per site; `passthroughHitTest` for overlays). Call sites unchanged.
- Drop-commit choreography shared via `EditorViewModel.commitDrop(...)`.
- Key-monitor guard hoisted to `noCommandModifiers` (identical semantics).
- `TimelineHeaderView` tooltips rebuild only when a bounds+per-track signature changes.
- `ExportCoordinator.waitWhileExportActive()` uses continuations resumed in `endExport()` (no 2s poll).

## Manual checklist — what YOU still need to test

Build: `scripts/bundle.sh debug --fast` → open `.build/Venice Video Creator.app` (grant Accessibility).

**Confirmed done:** ✅ 5.2 end-frame (Kling), ✅ 5.3 Wan audio, ✅ export cancel (Esc **and** Cancel
Export button — partial file removed), ✅ double-fire guard, delete-generating-placeholder,
transport/playback, bare-key menu guard, elapsed timer.

**Still to run (throwaway project):**
1. **Quit guard** — ⌘Q during a long export, and separately during a generation → the guard prompt
   must appear and **Cancel must actually stop the quit**.
2. **Resume** — start a video gen, quit + relaunch → it resumes and finishes (or fails with Retry),
   never shimmers forever.
3. **Delete scoping** — media folder selected AND a timeline clip selected, press ⌫ → only the clip
   dies, not the folder's media.
4. **Preview drop** — drag a media tile onto the preview canvas → highlights + accepts. Repeat over
   the timeline, media panel, and agent-input drop zones.
5. **Batch-sibling cancel** — generate a 4-image batch, delete ONE tile → the other three keep going.

**Optional (new this session):** click-to-import on reference slots; the Audio slot waveform icon.

## Ground rules (unchanged)
- Verify a flow by exercising it, not a clean compile. Commit one cluster at a time; push (CI validates).
- Non-regression is hard: new request params opt-in behind capability flags defaulting to current
  behavior; guardrails warn before they block; source media never mutated (pad/convert to temp).
- Test-suite gotcha: do NOT add `AVAssetExportSession` tests to the default suite (cross-suite
  parallelism → non-deterministic SIGTRAP). Use isolated `--filter` runs or live testing.
- Use targeted `git add <paths>`, not `git add -A` (the working tree has unrelated in-progress edits).

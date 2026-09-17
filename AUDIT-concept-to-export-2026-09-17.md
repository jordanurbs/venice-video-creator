# Concept-to-export audit and implementation plan

Date: 2026-09-17

## Verdict

The app has most of the individual tools, but the complete workflow is **not ready for a reliable end-to-end acceptance run**. The highest-risk defects are stage coordination: model routing, shot-to-clip identity, linked audio, QA gates, recovery, and completion reporting. Fix these before spending on a full production.

Target workflow: idea with the agent → saved concept/shot plan → character and location references → manual selection/corrections → automated storyboards → manual corrections/review → generated video → automated audio and agent-directed editing → verified export.

This is an audit and plan, not an implementation. Existing uncommitted app and harness changes were preserved.

## Scope and verification

- Read the current working tree, including uncommitted H3 Max changes and the new harness importer; older handoffs were treated as leads, not current findings.
- Compared app catalog, model mapping, request builders, UI/agent generation, production orchestration, references/storyboards, audio placement, persistence/recovery, timeline linking, and export reporting.
- Compared the local harness working tree at `~/projects/tools/venice-video-harness`; HEAD is `1a0be74`, with uncommitted Multi-Angle implementation, manifest changes, and tests. Those changes are not evidence of a published release.
- App manifest metadata says harness `2.18.0`; local harness snapshot says `2.27.0`. Content comparison found 14 harness-only video IDs, including Multi-Angle, and six changed shared entries. Metadata dates are not a reliable freshness test: current working-tree contents include later additions.
- `git diff --check` passed before this document was added.
- `swift build` was attempted with Swift 6.3.3 on arm64 macOS 26, but failed before app compilation because the sandbox denied compiler-cache access. Escalated approval failed. **Build and tests remain unverified**, not failed product tests.
- No paid generations, live catalog calls, GUI test, or exported-media acceptance run was performed. Harness API claims below are based on its recorded probe results, not fresh probes in this audit.
- This is a workflow-focused audit, not a full security, accessibility, performance, or pixel-level UI certification.

## Existing work to retain

The current tree already includes bounded agent request serialization and tests for large image/text payloads, `wait_for_media` registration grace, reference-slot allocation, locked style prompts, higher requested reference quality, four-reference agent creation, take recipes, measured dialogue reflow, initial ducking, output validation, QA-error annotations, parallel generation, and multiple export formats. These need integration coverage and targeted corrections, not wholesale rewrites.

H3 Max/Turbo support is **partial**, not absent: five lane IDs are already in the bundled manifest; simple-prompt handling, Max R2V audio-input fallback, and 768P preference are present. Multi-Angle has no app-side camera parameter plumbing.

## Confirmed findings

Priorities: **P0** blocks a trustworthy acceptance run or risks wrong paid output; **P1** is required for the requested quality/editing workflow; **P2** can follow the first accepted run.

### F01 — P0: Production status can serialize to `{}`

Evidence: `Agent/Tools/ToolExecutor+Production.swift:147–160` inserts `pendingQueue` (`[MultiShotPlanner.Unit]`) directly into a Foundation JSON dictionary as `queuedShotIds`. `Unit` is a Swift struct, not a JSON object. `ToolExecutor.swift:228–230` uses `JSONSerialization`; failure falls back to `{}`. A nonempty queue therefore loses the agent's progress report.

Fix: typed status DTO or explicitly map `pendingQueue.flatMap(\.shotIds)`; expose separate unit details if needed. Serialization failure must be an error, not success with an empty object. Separate succeeded, failed, cancelled, pending, and settled counts: `ProductionOrchestrator.swift:323` increments `completedCount` for failed units too.

Acceptance: poll a nonempty mixed queue through the actual tool dispatcher; valid JSON includes shot IDs and accurate terminal counts.

### F02 — P0: Explicit image-to-video models are bypassed, and inherited aspect is rejected

Evidence: `ProductionOrchestrator.swift:1037–1160` only routes ordinary I2V through frame chaining when the reference stack is empty. With a storyboard, it searches for R2V; an explicit Max/Turbo I2V selection can silently fall back to another model. Unknown/disabled overrides also become nil and fall back. `reconcile` at `1194–1214` returns the plan aspect when the model has no aspect list, but `VideoModelConfig.swift:83–85` rejects a nonempty aspect for those models. This breaks inherited-aspect I2V even when routing reaches it.

Fix: resolve explicit model/lane first. I2V takes the approved storyboard as `image_url`; R2V takes reference slots; T2V takes no image input. Missing required input or unavailable explicit model is a preflight error, not an undisclosed fallback. Separate API aspect (omitted for inherited-aspect models) from expected output aspect (measured from the source image). Reconcile resolution and duration once, shared by UI, agent, and production.

Acceptance: each Max/Turbo/Multi-Angle I2V override stays on the requested ID; an approved panel reaches `image_url`; `aspect_ratio` is absent; output validation still checks the intended framing. No request is submitted for an invalid override.

### F03 — P0: Multi-shot beats lack stable timeline identity

Evidence: `placeUnitClips` (`ProductionOrchestrator.swift:477–497`) assigns one generated asset to multiple shots but does not persist each beat's clip ID/source range on the shot. `productionClipId(forAsset:)` defaults to occurrence zero (`EditorViewModel+GeneratedClips.swift:223–233`). Dialogue positioning (`ToolExecutor+ProduceAudio.swift:227–231`), retakes (`ProductionOrchestrator.swift:627` vicinity), and reset paths resolve by asset alone. A later beat can target the first beat's clip.

Fix: persist a production binding per shot: video clip ID, linked audio IDs, take/unit ID, and source range. Migrate old projects conservatively; ambiguous bindings require reconciliation, not guessing. Use it for select, dialogue, retake, reset, delete, undo, and recovery. Validate grouping against adjacency in the full plan, not only the filtered list of requested/unplaced shots.

Acceptance: render three beats from one asset; dialogue starts at each correct beat; retake/reset the middle beat without touching the first or third; save/reopen preserves all bindings. A selection with an intervening placed shot does not group across it.

### F04 — P0: Production reordering and native-audio controls ignore linked audio

Evidence: `EditorViewModel.swift:424–482` creates separate linked video and audio clips for videos with sound. `reorderProductionClipsToPlanOrder` (`EditorViewModel+GeneratedClips.swift:180–218`) moves only video-track clips. `ProductionOrchestrator.swift:490–493, 843–847` applies mute/duck only to the video clip, while `Preview/CompositionBuilder.swift:54–68` builds audible content from audio tracks.

Fix: perform production placement, reorder, replacement, and audio mix changes through linked-group mutations. Apply native-audio policy to audible linked clips, including restoring `keep` after mute. Preserve manual edits and represent one operation as one undo transaction.

Acceptance: force jobs to finish in reverse order; video and linked sound remain aligned. Keep/duck/mute are audible in preview and export. Undo/redo and a retake retain alignment and mix policy.

### F05 — P0: Failed or unavailable QA does not stop placement; panel approval becomes stale

Evidence: `ProductionOrchestrator.swift:695–708` places a failed take when no retries remain. The grouped path at `449–465` has the same last-attempt behavior and reviews only the first shot’s rubric against the shared asset, not each beat’s source range. `runAutoQA:748–754` returns nil for unavailable dependencies/frames; exceptions are annotated UNCHECKED but still proceed to placement. `ToolExecutor+Production.swift:53–83` checks missing/UNCHECKED summaries, not a structured failure. `storyboard_shots:147–153` and `fix_panel:205–209` replace panels without clearing the old QA summary. `qa_shot` defaults to a ready video before a panel, so a panel correction can accidentally re-review the old video.

Fix: separate panel review from take review. Store reviewed asset/revision, pass/fail/unchecked/error, reviewer, and explicit human approval. Invalidate dependent reviews when prompts, panels, canonical references, or camera settings change. Failed final QA requires review, not `.placed`; QA transport errors retry QA, not paid video. Expose deliberate human override and its reason. Put gates in a shared production service so direct UI production cannot bypass tool-only checks.

Acceptance: fail every QA attempt, remove the vision model, throw a QA error, and replace an approved panel. None silently produces an approved/placed result. Explicit manual approval remains possible and is auditable.

### F06 — P0: Relaunch cannot reliably reconnect production or finish audio placement

Evidence: `submitAndAwait` (`ProductionOrchestrator.swift:737`) discards the placeholder ID, while `resume:97–115` requires `shot.videoAssetId`, which is assigned by `recordTake` only after completion. New pending shots can be marked interrupted even while their paid jobs remain recoverable. Retakes may still point at the old asset. `GenerationService.swift:369–376, 388–422` resumes without completion callbacks. Dialogue finalization/reflow lives in those callbacks and an in-memory `DialogueLaneBox`.

Fix: persist operation records when placeholders register, before upload/queue waits: stage, shot/line/unit IDs, placeholder, remote queue ID, submitted recipe, destination bindings, and retry state. Completion must reconcile durable state on both live and recovered paths, exactly once. Reapply validation, QA, audio sizing, and linked placement consistently.

Acceptance: interrupt during upload, remote generation, download, and QA, including a multi-shot take and a dialogue line. Reopen without duplicate paid jobs, lost associations, stale audio lengths, or premature placement.

### F07 — P0: Agent cannot verify export completion or final readiness

Evidence: `ToolExecutor+Export.swift:56–108` creates a task-local `ExportService`, returns `status: started`, and only posts OS notifications on completion/failure. There is no agent export-status/wait tool. The video tool checks a nonempty timeline, not settled generation, unresolved media, review state, or audio overhang.

Fix: retained export jobs with ID, progress, terminal result/error, warnings, output path, timeline revision, and measured output facts. Add `export_status` and `wait_for_export` (or a bounded wait option). Add production-readiness preflight; permit incomplete preview export only by explicit override. Export an immutable snapshot and clearly report if subsequent edits make it stale.

Acceptance: agent waits for a real terminal result; injected export failure reports failure; incomplete production is blocked for final export. Verify file decoding, dimensions, duration, audio, first/last frames, and no unexplained black tail. File existence alone is not completion.

### F08 — P1: Audio reruns, measured timing, and bed length are not coordinated

Evidence: `ToolExecutor+ProduceAudio.swift:86–120` creates a fresh local dialogue lane each call, with no persisted shot-line-to-clip identity or replacement policy. Repeating/partially rerunning audio appends duplicates and only reflows that invocation's lines. Duck windows at `164–180` use speech estimates, not final clip positions; callbacks at `105–108` do not recompute bed envelopes. `submitBed:204–216` places a planned-length bed, then `finalizeGeneratingClip` replaces its duration with the entire generated asset's duration. Reflow pushes speech later but does not extend or otherwise reconcile picture coverage.

Fix: durable dialogue/bed identities and explicit regenerate/replace/append behavior; preflight all selected IDs, voices, models, and parameters before any submission. Recompute timing and ducking from measured, current clips after generation and agent/manual edits. Fit/loop/crossfade/trim beds to the intended cut, not the provider's duration ladder. Handle speech overruns explicitly: rewrite, retime, approved hold/shot extension, or flag for editing. Preserve user automation separately from generated ducking. Score beds should request instrumental output unless vocals are intentional.

Acceptance: partial rerun replaces only selected lines; later lines never overlap; bed ducking follows real speech after trims/moves; a 60s generated bed does not extend a 35s cut to 60s. A long final line cannot create an unnoticed black tail.

### F09 — P1: On-screen dialogue has no completed exact-speech production lane

Evidence: video prompts include on-screen lines (`ShotPromptBuilder.swift:101–104`); `produce_audio` separately TTS-generates every nonblank dialogue line, including on-screen speech. `lipSyncEligible` (`ProductionOrchestrator.swift:1022–1034`) is only a decision hook, not an invoked generation strategy. A locked voice sample is not the exact utterance.

Fix: make speech ownership explicit per shot/line: native on-screen dialogue, external voice-over, or exact-speech lip-sync. Do not layer duplicate TTS over retained native dialogue. For exact on-screen speech, generate and measure the actual line first, feed that asset to a verified audio-input lane, then align and retain exactly one audible speech track. Unsupported models must report the limitation. This dependency is an exception to the otherwise video-then-audio workflow.

Acceptance: native dialogue is heard once; voice-over never induces visible speech; an exact-speech test uses the actual locked-voice utterance and passes human lip-sync review. Until this lane is implemented, label the first live scenario as VO/native-dialogue only, not full dubbed-dialogue acceptance.

### F10 — P1: Locked image model/quality can differ from the paid request

Evidence: `ImageGenerationSubmission.swift:82–99` routes reference-bearing images to edit/multi-edit without the selected resolution, quality, or seed. `VeniceGeneration.swift:52–60` maps non-edit model IDs to a generic edit fallback instead of the locked model's verified edit counterpart. The recorded input can still name the original model. Multi-edit aspect restoration center-crops (`ImageAspectRestorer.swift`), which can remove composition content. Seed support for reference images is deliberately disabled (`ToolExecutor+Generate.swift:279–291`), so seeded reference reproducibility is not currently promised by actual behavior.

Fix: explicit generation↔edit model mapping; preflight/report the effective model and supported output controls; persist the actual submitted recipe, including crop transform and measured output. Do not invent unsupported parameters to satisfy quality labels. Prefer a verified native-aspect lane; otherwise preview/approve crop or outpaint. Keep image seed disabled until probed and serialized end to end. UI reference regeneration defaults to two while agent creation defaults to four; unify the workflow or label the difference.

Acceptance: locked Nano Banana reference/storyboard workflows stay on the verified counterpart, not an unrelated editor. Stored provenance matches captured request bytes and actual dimensions; crop changes are visible before video production.

### F11 — P1: Retry spend and output validation are too optimistic

Evidence: `runningUSD` increases only for successful placement (`ProductionOrchestrator.swift:466,707`), excluding rejected paid takes; it is not reset with other per-run counters. `OutputValidator.swift` tests orientation rather than exact aspect, accepts 80% of requested duration, and returns pass for some probing errors. Duration reconciliation chooses the nearest rung, including shorter durations.

Fix: attempt ledger with quoted/reserved/actual-or-unknown cost, stage-specific retries, maximum attempts and user-approved run budget. Separate provider success from usable take and approved cut. Validate exact aspect within tolerance, finite duration, requested minimum/segment coverage, and decodable output; unreadable is unchecked/retry-probe, not passed. Choose a sufficient duration rung or require explicit shortening.

Acceptance: QA-rejected paid takes remain in spend/provenance; unknown billing is labeled. A wrong landscape aspect and an undersized grouped take cannot pass merely because orientation matches. No unlimited retry loop or silent shortening.

## MiniMax H3 Max / Turbo / Multi-Angle integration

### Required model contract

Based on the current harness registry and its recorded September probes:

| Lane | Exact ID | Duration | Resolution | Input |
|---|---|---|---|---|
| Max T2V | `minimax-h3-max-text-to-video` | Integer 5–15s | 768P, 480P | Text; supported aspect list |
| Max I2V | `minimax-h3-max-image-to-video` | Integer 5–15s | 768P, 480P | Start image; inherits aspect |
| Max R2V | `minimax-h3-max-reference-to-video` | Integer 5–15s | 768P, 480P | Up to 9 reference images; verified `audio_url` support |
| Turbo T2V | `minimax-h3-max-turbo-text-to-video` | Integer 5–15s | 768P, 480P | Text; supported aspect list |
| Turbo I2V | `minimax-h3-max-turbo-image-to-video` | Integer 5–15s | 768P, 480P | Start image; inherits aspect |
| Multi-Angle | `minimax-h3-max-multi-angle` | Integer 5–15s | 1080P, 768P, 480P | Start image + camera trajectory; inherits aspect |

No Turbo R2V exists in the registry/probes. A family-level Turbo identity request may offer **explicitly disclosed** Max R2V; an exact model request must never silently switch. These models use simple prompts, have native audio that is not toggleable, and do not accept an end image. Omit `audio` and unsupported input/aspect fields. Multi-Angle's prompt may be absent; camera motion must satisfy prompt/preflight/UI requirements without dummy text.

### The six visible settings

Place a **Camera Move** section in generation settings and the shot inspector, visible only for Multi-Angle:

| Setting | API representation |
|---|---|
| Start horizontal angle (degrees) | First keyframe `azimuth` |
| Start vertical angle (degrees) | First keyframe `elevation` |
| Start camera distance | First keyframe `distance` |
| End horizontal angle (degrees) | Last keyframe `azimuth` |
| End vertical angle (degrees) | Last keyframe `elevation` |
| End camera distance | Last keyframe `distance` |

These are **not six top-level API fields**. Serialize as:

```json
{
  "camera_trajectory": [
    { "time": 0, "azimuth": 0, "elevation": 0, "distance": 1 },
    { "time": 1, "azimuth": 90, "elevation": 0, "distance": 1 }
  ]
}
```

The numbers above are an example quarter-orbit, not a hidden paid-generation default. Make the selected move visible and user/agent editable before submission. Distance is relative, not meters: 1 unchanged, below 1 closer, above 1 farther.

Shared validator: 2–12 keyframes; finite numbers; times in [0,1], strictly increasing; elevation in [-90,90]; distance > 0; sum of absolute adjacent azimuth changes ≤ 11,520 degrees (32 turns). The six-control editor emits endpoints at 0 and 1. Preserve advanced 3–12-frame trajectories on reopen/edit; do not silently collapse them into two endpoints. Reject explicitly supplied trajectories on unsupported models.

### Plumbing checklist

1. Capture a reproducible harness snapshot and verify registry/manifest agreement. Add optional `supportsCameraTrajectory` decoding with conservative false default; the current app ignores it. Coordinate schema-version policy with the harness sync rule (the present harness added the field while retaining schema 1); update compatibility tests before publishing.
2. Carry capability and prompt-optional/input-lane semantics through catalog mapping, `VideoCaps`, `VideoModelConfig`, `list_models`, and model pickers. The capability snapshot supplements the live catalog; copying it alone does not create picker entries for delisted models. Only add supplemental IDs with verified availability.
3. Add a shared Codable camera trajectory value; persist on shots, generation input, take recipes, and operation records. Old documents decode to nil. Keep export/import and regeneration compatible; preserve any trajectory supplied by harness imports rather than silently dropping it.
4. Thread through shot tools, direct `generate_video`, `VideoGenerationSubmission`, backend parameters, and `VeniceGenerationRunner.runVideo`. Validate before upload/quote/queue; a rejected move must consume no generation credits.
5. Add the six controls using only `AppTheme` tokens, with units, validation, reset, undo, and accessible labels. Use native AppKit for any enclosing drop target. Keep UI, inspector, and agent backed by the same settings/validator.
6. Handle Multi-Angle before broad H3 Max family fallbacks. Distinguish maximum supported resolution from auto default: recommended production default is 768P, with explicit 1080P plus refreshed quote, matching the harness's cost-conscious video path. Do not infer auto default from array ordering alone.
7. Make grouping capability-aware. An explicit camera trajectory is a single-shot I2V operation, not a `Lens switch.` R2V montage. H3 simple-prompt behavior must apply to grouped Max R2V too, or grouping must stay disabled for that lane until verified.
8. Add request-body fixtures for all six IDs, negative/boundary trajectory tests, missing-frame tests, no-prompt tests, resolution-order/load-race tests, persistence/undo/retake tests, and old-project decoding tests. Reconcile live quotes and constraints before a small paid smoke run.

## Implementation order and exit gates

| Phase | Work | Exit gate |
|---|---|---|
| 0 — Baseline | Review/preserve current diffs; obtain permitted macOS build/test run; add injectable catalog, generation, QA, clock, and export seams; capture fixtures | Existing suite/build results recorded; new failing regressions reproduce F01–F07 without paid calls |
| 1 — Model contract | F02 + complete Max/Turbo/Multi-Angle integration | All six lane request fixtures pass; camera controls survive save/reopen; no silent model substitutions |
| 2 — Production identity | F01, F03, F04, F06; durable shot/line/job bindings and linked mutations | Out-of-order, multi-shot retake, reset, partial rerun, undo, and relaunch fixtures pass |
| 3 — Review and references | F05, F10, stricter validation/spend from F11 | Manual reference/panel edits invalidate only affected approvals; rejected/unchecked media cannot silently advance |
| 4 — Audio finishing | F08 and F09; audio ownership, measured schedule/ducking, bed fitting, exact-speech lane | No duplicates/overlap; real-time edits and reopen preserve alignment; explicit speech-overrun handling |
| 5 — Verified delivery | F07; final-readiness report, export jobs/wait, artifact validation | Agent receives a verified completion report or actionable failure; deterministic full workflow passes |
| 6 — Live acceptance | Fresh catalog/quotes, approved budget, short model probes, complete human-in-the-loop run | Checklist below passes; artifacts and residual issues saved |

Treat paid request changes as explicit, reviewed behavior changes. Keep unrelated/deferred capabilities (`elements[]`, scene-image builders, per-reference audio objects) off; a manifest refresh must not accidentally enable them. Do not change the global default video family merely to add MiniMax support.

## End-to-end test specification

### A. Deterministic integration run — no paid services

Use the real tool dispatcher/editor state and generation/export coordinators with injected provider responses. Script the agent conversation where determinism matters; this proves the application pipeline, not live model reasoning. Separately exercise the real agent's request assembly/context budgeting with large transcripts and tool outputs. Use valid local image/video/audio fixtures, not arbitrary bytes.

Fixture: a 35–50s short film, two characters, two locations, six shots, one narration line, a two-line dialogue exchange, a music bed, and ambient/SFX. Include a two-beat shared video asset and a separate Multi-Angle move. Supply outputs in deliberately reversed completion order and TTS durations longer than estimates.

Required assertions:

- Concept and shot plan are saved; prompts distinguish still composition from motion; shot IDs and references remain stable.
- All generation parameters, quotes, job IDs, and actual model choices are captured without logging secrets or raw image payloads.
- Character generation finishes; manually choose a different canonical reference and voice; update wardrobe text; only affected review/dependency state changes.
- Generate storyboards; edit/reframe one, regenerate one, undo/redo, and explicitly approve final revisions. Unapproved replacements cannot inherit old approval.
- Generate video with exact model/input contracts; wait through structured statuses. Shared-asset beats retain distinct timeline bindings.
- Generate audio, partially regenerate one line, alter timing/volume/fades with agent tools, then manually trim another line. Reflow and bed ducking follow measured clips and preserve human edits.
- Stop/reopen at a pending video and pending audio checkpoint; resume without duplicate submissions or lost finalization.
- Final preflight catches missing/failed media, unchecked QA, unresolved speech ownership, overlap, bed overhang, and unexpected picture gaps.
- Export an H.264 1080p master and a portable project; await terminal job result; decode the movie and inspect beginning/middle/end plus audio; reopen the portable project with all required media.

Add failure cases: missing key/model, denied consent, invalid camera input, strict queue 400, throttling, timeout, transient QA outage, truncated/wrong-aspect media, save/reopen, disk/export failure, and edits during export. Each must terminate or remain explicitly pending with a bounded retry policy, never claim success or silently resubmit paid work.

### B. Native UI/manual-tweak run

Add a UI test host/accessibility identifiers or a documented repeatable manual harness; no `XCUIApplication` test target currently exists. Cover canonical-reference selection, reference drag/drop, panel corrections, all six camera controls, reorder/trim/fades, undo/redo, save/reopen, and export progress. Leaf drops must still work beneath enclosing native drop areas. A tool-only test is insufficient evidence for the requested manual-tweak workflow.

### C. Paid live acceptance — only after A and B pass

- Use a fresh test project, live model constraints/quotes, confirmed model/face consent where applicable, a user-approved total spend cap, and per-stage stop points. Confirm local harness changes are published or intentionally vendored; do not assume auto-update has them.
- First run minimum-duration Max, Turbo, and Multi-Angle probes. Verify actual dimensions/audio/trajectory behavior and the six settings. Quote the explicit 1080P Multi-Angle probe separately. Refresh affected request fixtures if live truth differs.
- Ask the real in-app agent to develop the fixture film from the concept. Require plan approval, canonical character/voice choices, and storyboard approval before production. Keep the whole workflow in the same project/conversation to exercise context growth.
- Produce the short; inspect one retake and one camera change. Run automated audio creation, request an agent edit, and make one manual timeline edit. Include exact-speech lip-sync only after F09's lane is complete; otherwise report that coverage as outstanding.
- Save/reopen, finish, and export through the agent. Do not accept “export started” as the outcome.
- Save the concept/plan, final reference and panel choices, redacted tool transcript, requested/submitted settings, job/take ledger, cost report, QA/approval records, timeline/project, export report, and output file facts.

**Pass criteria:** no unapproved model substitutions or duplicate paid jobs; intended character/shot identity survives tweaks and retakes; video and linked audio stay aligned; dialogue is audible once, untruncated, and intentionally timed; music/ambience span the intended cut with correct ducking/fades; Multi-Angle settings reach the provider; recovery preserves work; final movie decodes and plays correctly with no unexplained black tail; the agent reports verified export completion and all remaining warnings.

## Follow-up, not a substitute for the exit gates

P2: advanced camera-path presets/curve editor, broader model-family parity beyond the requested MiniMax lanes, contact-sheet continuity review, automated cut/audio quality scoring, performance profiling, and a wider accessibility/security audit. Keep the existing importer under round-trip regression coverage, but do not make importing a harness project a prerequisite for the in-app concept-to-export workflow.

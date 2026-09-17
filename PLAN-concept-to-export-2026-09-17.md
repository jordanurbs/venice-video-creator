# Concept-to-export remediation plan

Date: 2026-09-17
Status: routing `c36247d`, catalog/1080P `fa3e067`, storyboard approval `563608c`, native fixture `d9f2975`, placement bindings `f3542fb`, and operation lifecycle `d0b4bc9` committed. Shared live/recovered video finalization compiled and regression-tested. Native control acceptance remains unverified after the background-window accessibility blocker. No phase exit or dated E2E acceptance has passed.
Evidence and detailed acceptance cases: `AUDIT-concept-to-export-2026-09-17.md`.
Session instructions: `HANDOFF-concept-to-export-2026-09-17.md`.

## Objective

Make the native app reliable for an in-app agent workflow: concept and idea → saved shot plan → generated character/location references with manual selection and tweaks → automated storyboards with manual correction and approval → video production → automated audio generation and agent/manual editing → verified export.

Complete MiniMax H3 Max, Max Turbo, and Max Multi-Angle integration, including six camera settings. Support is not complete until UI, agent, persistence, routing, request serialization, recovery, and export acceptance agree.

## Execution rules

- Read `AGENTS.md` and the current working-tree diff before editing. Both app and harness contain user work. Do not reset, overwrite, or commit unrelated changes.
- Treat the dated audit as evidence to verify against current code, not a reason to repeat the entire audit. Line numbers may move.
- Keep changes in reviewable phases. Add regressions for each defect and record commands, results, remaining issues, and changed files here or in a dated validation report.
- Use `AppTheme` for all styling; add missing tokens there. Keep comments minimal. Enclosing drop targets must use native AppKit.
- Do not enable unrelated deferred provider features or change the global default video family.
- No paid calls or full live E2E without explicit spend approval. A queued job or an existing output file is not proof of success.
- Normal Swift build/tests are authorized and working in the continuation environment. Earlier approval-service failures were infrastructure blockers; no cache relocation or indirect execution was used.

Checklist convention: checked items record the stated implementation or validation milestone, not overall readiness. Exact verification and remaining scope are recorded in `VALIDATION-concept-to-export-2026-09-17.md`.

## Phase 0 — Baseline and deterministic test seams

- [x] Inventory current app/harness diffs; preserve partial H3 work and the untracked harness importer/tests.
- [x] Obtain an authorized macOS build/test run and record the baseline. Normal `swift build` and `swift test` ran on 2026-09-17; compiler errors and camera agent-undo failure fixed. Full suite reports 1,058 tests in 165 suites passing, with six model-dependent tests skipped.
- [ ] Establish injectable catalog, provider generation, QA, clock, and export boundaries using existing abstractions where possible.
- [ ] Add valid local image/video/audio fixtures and regression coverage reproducing F01–F07 without paid calls.

Exit: build/test baseline is known, new regressions reproduce the defects, and deterministic workflow tests need no live credentials.

## Phase 1 — Routing and full MiniMax contract (F02)

- [x] Resolve explicit model/lane before fallback; reject unknown, unavailable, or incompatible overrides with an actionable error. Never silently substitute a paid model.
- [x] Guard superseded catalog success/error callbacks and bind native video picker selection to model ID. Block video submissions during catalog reload and when the selected model disappears.
- [ ] Route approved storyboard frames to I2V, reference slots to R2V, and no image inputs to T2V. Separate inherited output aspect from the omitted API `aspect_ratio` field.
  - Storyboard approval gates entry/routing/preparation/submission and finalization. MiniMax inherited expected output aspect now comes from the decoded original first frame. Exact output ratio/resolution floors still need stronger decoded-facts checks in Phase 3.
- [ ] Reconcile the app manifest and local harness contract. Coordinate schema policy for `supportsCameraTrajectory`; a manifest refresh must not accidentally activate unrelated capabilities.
- [ ] Verify live catalog availability before supplementing missing picker models; the bundled capability snapshot is not a catalog.
- [ ] Introduce one shared Codable trajectory type and validator, with backward-compatible nil defaults. Persist through shot settings, generation inputs, take recipes, durable operations, harness import, and project round trips.
- [ ] Thread camera settings through shot tools, direct generation, submission/backend parameters, and the final Venice request builder. Validate before upload, quote, or queue.
- [ ] Add six accessible inspector/settings controls, reset, validation, undo, and agent schema support. Preserve advanced trajectories rather than flattening them on load/edit.
- [x] Handle Multi-Angle before broad family fallbacks. Keep explicit camera moves single-shot; make grouped Max R2V simple-prompt behavior capability-aware or leave that grouping disabled until verified.
- [x] Separate automatic resolution from maximum supported resolution: Multi-Angle defaults to 768P (480P if that is the only lower tier); automatic mode never selects 1080P. Explicit 1080P requires a fresh queue-boundary quote and a per-request cap shared by retries/batch attempts. This is not the durable all-lane attempt ledger in Phase 3.
- [ ] Test every lane's request body, inherited aspect, unsupported combinations, missing image, absent Multi-Angle prompt, trajectory boundaries, resolution load races, undo/retake, and old-project decoding.

Exit: all six lane fixtures pass, selected models are honored, and the six camera settings survive save/reopen and reach the serialized provider request.

### MiniMax contract checklist

The local harness has recorded probes; these are not fresh live verification. Harness path: `/Users/venetian42069/projects/tools/venice-video-harness`. At audit time HEAD was `1a0be74`, and Multi-Angle changes were uncommitted. App/harness manifest metadata was `2.18.0`/`2.27.0`; do not assume those local changes are published.

| Lane ID | State at audit |
|---|---|
| `minimax-h3-max-text-to-video` | Partial app support |
| `minimax-h3-max-image-to-video` | Partial app support; routing/aspect defects |
| `minimax-h3-max-reference-to-video` | Partial app support |
| `minimax-h3-max-turbo-text-to-video` | Partial app support |
| `minimax-h3-max-turbo-image-to-video` | Partial app support; routing/aspect defects |
| `minimax-h3-max-multi-angle` | Missing app camera plumbing |

- All lanes: integer durations 5–15 seconds; no end frame; native audio is not toggleable, so omit `audio`.
- Max/Turbo resolutions: 768P, 480P. Multi-Angle: 1080P, 768P, 480P.
- I2V inherits source aspect: omit `aspect_ratio`.
- No Turbo R2V. Offer Max R2V explicitly, not as a silent replacement.
- Max R2V accepts up to nine image references and `audio_url`.
- Use simple prompts. Multi-Angle may omit the prompt.
- Six settings: start/end horizontal angle (`azimuth`), vertical angle (`elevation`), and relative distance (`distance`). Serialize as two `camera_trajectory` keyframes, not six top-level request keys:

```json
{
  "camera_trajectory": [
    {"time": 0, "azimuth": 0, "elevation": 0, "distance": 1},
    {"time": 1, "azimuth": 90, "elevation": 0, "distance": 1}
  ]
}
```

Advanced trajectories: 2–12 keyframes; finite values; strictly increasing time in [0,1]; elevation in [-90,90]; distance >0 (1 means unchanged, not meters); total absolute consecutive azimuth changes ≤11,520°.

Harness evidence: `src/venice/models.ts`, `src/venice/types.ts`, `tests/camera-trajectory.test.mjs`, and root `capabilities.json`.

## Phase 2 — Durable production identity and recovery (F01, F03, F04, F06)

- [x] Fix production status JSON using typed output or flattened shot IDs; never return success with `{}` after serialization failure. Separate succeeded, failed, cancelled, pending, and settled counts.
- [ ] Persist shot→clip/linked-audio/take/unit/source-range bindings. Replace asset-only lookup in dialogue, retakes, resets, selection, and deletion. Reconcile ambiguous legacy bindings instead of guessing.
  - [x] Persist placement video/audio clip IDs, assigned source window, take ID, and grouped take unit ID. Retake/reset/dialogue/recovery lookup uses exact bindings. Unique legacy clips migrate; ambiguous cases require explicit `update_shots.placedClipId` reconciliation, including shortened tool IDs. Selection previews, split descendants, and arbitrary timeline source replacement still need reconciliation work.
- [x] Validate grouping adjacency against the full plan, not just the requested subset.
- [ ] Make placement, reorder, replacement, and keep/duck/mute operate on linked clip groups. Restore audio when returning to keep; preserve manual edits and one-operation undo.
  - [x] Retake/reset acts on the exact pair; replacement preserves edited timing, fades, and mix. Grouped replacement rolls back atomically and supports one-operation undo/redo. Reordering uses clip identity, moves linked partners, and rejects new manual clip/audio overlaps. Keep/duck/mute policy changes and broader manual timing ownership remain open.
- [ ] Persist stable operation and line identities before asynchronous waits, including placeholders, remote queue IDs, recipes, destination bindings, stage, and retry state.
  - [x] Video production records run/operation IDs and destination revisions before waits, and distinct attempt/per-shot take IDs before submission. The shared generation service checkpoints the placeholder with those records before preparing references; backend/queue IDs and stage/failure metadata are retained. Native production awaits an autosave callback and requires a saved project. Audio line IDs and complete recovery finalization remain open.
- [ ] Reconcile live and recovered completion exactly once, including validation, QA, measured audio lengths, reflow, and linked placement. Do not depend on ephemeral callbacks.
  - [x] Owned unit tasks and run/operation/attempt guards reject stale completion, validation, and QA after cancellation/restart or shot/destination edits. Interrupted new-format operations are retained for review on reopen; automatic recovered finalization is deliberately still incomplete.
  - [x] Live and explicitly resumed video attempts share content-hash validation, persisted per-beat reviews, and linked placement. `resume_production` and the native Finish Existing Take control finalize the retained attempt without video submission. Repeated/concurrent calls, cancellation, undo, and failed final-save retry are covered; real native crash/queue/download acceptance and audio finalization remain open.
- [ ] Test reversed completion order, shared-asset middle-beat retakes/resets, partial reruns, undo/redo, and reopen during upload, generation, download, and QA.

Exit: status remains readable, the intended beat is always edited, linked sound stays aligned, and recovery neither duplicates paid jobs nor loses finalization.

## Phase 3 — Review gates, reference fidelity, and validation (F05, F10, F11)

- [ ] Separate panel and take reviews; bind verdicts to asset/revision, reviewed source range, reviewer, and human approval/override reason.
  - [x] Production finalization records content digest, source range, reviewer, QA verdict, and any reasoned human override per beat. Passed ranges are reused only for the same video digest and source range. The standalone `qa_shot` take path and later arbitrary timeline edits still need integration with this evidence.
- [ ] Invalidate affected dependencies after canonical-reference, prompt, panel, or camera edits. Let `qa_shot` explicitly target the intended artifact rather than silently prefer old video.
- [ ] Enforce shared UI/tool service gates: failed or unavailable QA cannot silently place/approve media. Retry QA transport errors without buying another take; review every grouped beat's range/rubric.
- [ ] Preserve supported image-edit model, resolution, and quality; record actual submitted provenance. Reject unsupported settings or request explicit fallback approval. Address aspect-changing multi-edit crops. Do not enable image seeds before verified support.
- [ ] Track every attempted/rejected/cancelled generation and cost, reset per-run counters correctly, enforce budgets, and retain a durable ledger.
- [ ] Tighten decoded media dimensions, duration, and source-range coverage checks; probe errors must not pass validation.
- [ ] Test all-failed QA, missing vision dependency, transport failure, stale panel approval, grouped beat review, manual override, and exact submitted image recipe.

Exit: unreviewed or stale media cannot silently advance, manual approvals remain possible and auditable, and quality/cost reports reflect actual attempts.

## Phase 4 — Measured audio finishing and speech ownership (F08, F09)

- [ ] Make audio reruns idempotent per durable line/role identity; partial edits replace intended audio without duplicates.
- [ ] Size dialogue from decoded output and recompute timing/ducking after generation, trim, move, retake, and reopen.
- [ ] Fit music/ambient beds to the intended cut rather than full provider duration; retain intentional fades and manual edits.
- [ ] Handle speech overruns explicitly against picture timing; never silently push dialogue into an unrelated shot.
- [ ] Separate native speech, voiceover, and exact on-screen speech. Ensure each line is audible once; do not blindly add TTS over native dialogue.
- [ ] For exact-speech/lip-sync, route the actual generated utterance through a verified audio-input model and validate synchronization. Keep this lane incomplete in reporting until implemented and tested.
- [ ] Test long TTS, partial regeneration, linked native-audio policy, agent edits, measured ducking/fades, undo, and reopen.

Exit: intelligible, untruncated, intentionally timed speech; no duplicate lines; beds cover only the intended cut; exact-speech coverage is truthful.

## Phase 5 — Readiness and verified delivery (F07)

- [ ] Add a shared final-readiness report covering pending jobs, stale approvals, media errors, missing bindings, and audio/timeline issues.
- [ ] Retain export jobs with stable IDs and query/wait tools; report terminal success/failure through the agent, not just OS notifications.
- [ ] Export an immutable project/timeline revision and report which revision was delivered.
- [ ] Verify decoded artifact tracks, dimensions, duration, audio, and intended timeline coverage; expose actionable errors rather than file-existence success.
- [ ] Complete deterministic integration and native manual-tweak acceptance before live spending.

Exit: the agent reports verified completion or an actionable failure, and the full no-paid workflow passes.

## Phase 6 — Human-in-the-loop and paid live acceptance

Use the audit's detailed test specification; retain three distinct evidence levels:

- [ ] **Deterministic integration:** real dispatcher/editor/coordinators with injected provider responses and valid media. Fixture is a 35–50s film, two characters, two locations, six shots, shared-asset beats, a separate Multi-Angle shot, VO/dialogue/music/ambient, reversed completion, and long TTS. Exercise retakes, partial audio reruns, recovery, and verified export.
- [ ] **Native UI/manual tweaks:** reference/voice selection, wardrobe edit, panel correction/regeneration/approval, six camera controls, drag/drop, reorder/trim/fades, undo/redo, save/reopen, and export progress. No existing UI automation target was found; add one or record a reproducible manual checklist. Tool-only testing does not certify this layer.
- [ ] **Paid live smoke:** only after the above pass and a total spend cap is approved. Refresh live catalog/quotes; verify whether harness changes are published or intentionally vendored. Run minimum-duration Max, Turbo, and Multi-Angle probes first; quote 1080P separately.
- [ ] **Real agent E2E:** fresh project, same conversation, staged approval of concept/plan, references/voices, and storyboards. Generate the film, do a retake/camera change, generate audio, request an agent edit, make a manual timeline edit, reopen, export an H.264 master and portable project, and verify delivery.
- [ ] Save redacted transcript, submitted settings, chosen assets/revisions, job/take/cost ledger, approvals, project, validation report, and exported-media facts. Do not retain credentials or raw image payloads in logs.

Final acceptance: no silent model substitution or duplicate jobs; character and beat identity survives edits; video/audio remain aligned; speech occurs once and fits intentionally; beds/ducking/fades are correct; Multi-Angle settings reach the provider; recovery preserves work; the movie decodes and plays without an unexplained black tail; the agent reports verified completion and residual warnings.

## Out of scope for first acceptance

Advanced camera curve editor/presets, unrelated model-family parity, deferred `elements[]`/scene-image/per-reference-audio features, global default model changes, and a comprehensive security/accessibility/performance audit. Preserve importer round-trip coverage without making harness import a prerequisite for the in-app workflow.

## Progress log

- 2026-09-17: Audit and implementation plan saved. Application code unchanged by this planning task. Build/tests, native UI, and live E2E remain unverified. All implementation checkboxes intentionally remain open.

- 2026-09-17 implementation: preserved and extended the related Max/Turbo, importer, canonical-reference selection, and capability-sync work. Added typed production status, exact selected-model resolution, storyboard-first automatic routing, shared trajectory persistence/validation and six controls, strict six-lane request validation, and deterministic request/dispatcher tests. Full-plan grouping adjacency is enforced; camera and simple-prompt groups stay single.
- Validation: source/data checks only; Swift build approval was again rejected before execution by the approval reviewer. Tests, UI, save/reopen, recovery, and export acceptance remain unverified. No paid calls, live catalog probes, or sibling-repository edits. See the dated validation report for scope and continuation.
- Source review follow-up: added a visible Remove action for unsupported camera state, guarded stale audio quotes, corrected optional model metadata, rejected explicit T2V with visual inputs and fractional MiniMax durations, and replaced the PNG fixture with CRC-checked data. Unrelated Seedance bitrate request hunk is preserved and flagged in the validation report, not included in the proposed commit.
- Commit attempt: staging approval rejected before execution by the automatic reviewer. Index unchanged; no commit created. All related work and the flagged unrelated bitrate hunk remain preserved. Authorized build/tests and Git writes are the next gates; no bypass attempted.
- 2026-09-17 continuation: normal build execution restored. Fixed camera-array decoding and Swift 6 transfer of the extracted request dictionary. A targeted regression exposed agent undo ignoring shot-plan-only changes; extended its snapshot guard and added manual-edit protection and malformed-camera regressions. Targeted 115 tests pass; full Swift suite reports 1,058 tests in 165 suites passing (six model-dependent skips). Existing local export tests ran; the dated 35–50s workflow, native UI, recovery, and paid acceptance remain open.
- First slice committed: `c36247d` (`feat(production): implement status and MiniMax camera routing contracts`), 48 files, after staged-diff review. Only the explicitly excluded Seedance bitrate hunk remained unstaged.
- Catalog/1080P follow-up: injectable catalog loader, superseded-result guards, key-removal clearing, stable video selection, and loaded/enabled model checks before reference preparation and final queueing. Added an ephemeral 1080P spending cap through UI, agent, production retries, service/backend, and final request runner; reruns cannot inherit approval from recipes. New catalog/budget tests and existing contracts pass: targeted 32 tests in seven suites; full suite reports 1,070 tests in 167 suites passing (same six skips). Native acceptance and revision-approved storyboard routing are next; phases 2–6 remain open.
- Catalog/1080P follow-up committed as `fa3e067` (`fix(generation): guard catalog refreshes and budget 1080P attempts`), with the unrelated bitrate block still excluded.
- Storyboard approval slice: added Codable image/settings revision fingerprints, separate panel verdict and reasoned human approval, invalidation through shared plan mutations, explicit `qa_shot` artifact selection with injected evaluator, stale-response rejection, and production recipe bindings rechecked before queueing. Native approval controls added to inspector and Production panel. Targeted 26 tests in four suites pass; full suite reports 1,079 tests in 168 suites passing (six skips). Take QA, grouped range review, post-generation callback safety, durable operations, and native acceptance remain open. CuaDriver is installed/running with Accessibility and Screen Recording grants; this establishes UI-test prerequisites only.
- Storyboard approval committed as `563608c` (`feat(production): bind storyboard approval to reviewed revisions`), with the unrelated bitrate block excluded.
- Native fixture continuation: added a real `.venice` package round trip with a decodable 640×360 image and a three-keyframe Multi-Angle path. Targeted fixture run passed both tests; full suite reports 1,081 tests in 169 suites passing (six model-dependent skips plus the opt-in retained fixture writer). Bundled and launched the retained fixture through CuaDriver; image/timeline rendered and media resolved. The background window is on another Space and exposes only menu-bar AX elements, so camera/approval/undo/retake/save-reopen controls remain unverified. Normal free catalog/capability requests occurred during launch; no paid generation or live lane acceptance. Continue durable shot-to-clip identity while native interaction is blocked.
- Native fixture/evidence committed as `d9f2975` (`test(production): add native camera project fixture`).
- Durable placement slice: added backward-compatible shot placement and take source-window/unit metadata; exact shared-asset middle-beat retake/reset/dialogue addressing; safe legacy reconciliation; linked audio movement and atomic grouped replacement. A real local H.264 package reopened with preserved clip IDs/ranges, and repeated reconciliation did not duplicate existing placements. Targeted 30 tests in four suites passed; full suite reports 1,093 tests in 170 suites passing (seven skips). Final shortened-ID repair passed 18 tests in two suites. Pre-wait operation persistence, cancellation/restart-safe finalization, split ownership, take QA, native acceptance, audio finishing, and export acceptance remain open.
- Placement bindings committed as `f3542fb` (`fix(production): persist exact shot placement bindings`), excluding the unrelated bitrate hunk.
- Operation lifecycle slice: added manifest-persisted operation/attempt records, awaited pre-submit checkpoints, stable take IDs, queue/placeholder provenance, operation summaries, and cancellation/revision guards around asynchronous work. Failed or unavailable auto-QA cannot place at the retry limit. Targeted 36 tests in four suites and full 1,104 tests in 171 suites pass (seven skips); final failure-detail preservation passed the 11-test operation suite. Reopen retains interrupted operations for review; shared live/recovered finalization, every grouped beat's revisioned QA, durable audio lines, and native autosave acceptance remain open.
- Operation lifecycle committed as `d0b4bc9` (`fix(production): persist attempts and guard cancelled operations`), excluding the unrelated bitrate hunk.
- Shared finalization slice: one path for live and retained video attempts; streamed SHA256 identity, planned-duration coverage, saved per-beat QA/override evidence, explicit resume without new generation, and exactly-once linked placement in deterministic tests. Inherited MiniMax aspect derives from the decoded first frame; undecodable/non-finite output facts fail validation. Fixed asynchronous take undo grouping and final-save retry/counting; one attempt cannot be rebound to a second placeholder. Targeted 46 tests in five suites and full 1,118 tests in 172 suites pass (seven skips). Native controls and actual server queue/download recovery remain unverified; durable audio-line identity and finishing are next.

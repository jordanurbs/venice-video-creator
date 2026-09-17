# Concept-to-export implementation validation

Date: 2026-09-17
Status: routing `c36247d`, catalog/1080P `fa3e067`, storyboard approval `563608c`, native fixture `d9f2975`, placement bindings `f3542fb`, and operation lifecycle `d0b4bc9` committed. Shared live/recovered finalization compiled and regression-tested. Native control acceptance remains unverified. Not E2E-ready.

## Permissions and spending

- The user explicitly authorized normal Swift build/tests (including compiler-cache writes) and Git staging/commit. Earlier retries were rejected before execution by the automatic approval reviewer (`ZodError`). The continuation environment now executes normal `swift build` and `swift test` successfully. No alternate caches, indirect builds, or tests were used to bypass a denial.
- No paid requests or fresh live quote/lane probes. Native fixture launch made normal free catalog/capability requests; it does not establish live lane availability. Existing local export regression tests ran as part of the full suite; the dated concept-to-export acceptance fixture has not run.
- Sibling harness was read only. Its uncommitted Multi-Angle contract is local evidence, not evidence of publication. No sibling files were changed.

## Preserved work and implemented scope

- Related inherited changes retained: Max/Turbo manifest/capabilities/prompts/tests, harness import and menu/window integration, source metadata, canonical character/location reference selection, and sync policy. Unrelated request-body change flagged for later: the Seedance 2.5 `bitrate_mode: "high"` block in `Venice/VeniceGeneration.swift` is preserved in the working tree and excluded from the proposed commit. Its origin is not established by the continuation summary; no claim is made that it is verified or required by this slice.
- F01: typed JSON production status with flattened shot IDs, queued shot/unit counts, nullable state, separate success/failure/cancellation/settled/pending accounting, and explicit encoding failure. The injected unit executor supports no-provider dispatcher regression tests. Run identity guards prevent old loop cleanup from replacing new run counters; unstructured in-flight production tasks/callbacks still need cancellation/restart and durable recovery work, so old callbacks are not proven safe against a new run.
- F02: resolve selected shot/default IDs before automatic routing; reject unavailable selections; storyboard/chained frames route to I2V, references to R2V, no visuals to T2V when automatic. Inherited MiniMax I2V aspect is omitted from provider requests/quotes. The later storyboard slice requires current panel approval; decoded-image-derived expected output aspect and native acceptance remain open.
- Shared Codable camera array and validator, shot/generation/recipe/import persistence, agent schema and patch support, six accessible endpoint controls, and final request serialization. Advanced interior keyframes survive endpoint edits; reset deliberately replaces the path. Durable operations and full project recovery still require Phase 2.
- Exact Multi-Angle capability handling, automatic 768P, simple prompts, optional Multi-Angle prompt, and no camera grouping. Max simple-prompt grouping is disabled. Full-plan adjacency blocks grouping a subset across omitted shots.
- Strict six-lane MiniMax request contract: duration/resolution, image/reference lanes, inherited aspect, omitted native-audio toggle, and early invalid-input rejection. Follow-up adds a mandatory fresh-quote/budget gate at the final video runner for explicit Multi-Angle 1080P, with pre-preparation budget checks in the shared service.
- Manifest adds the local Multi-Angle specification without replacing global defaults or supplementing absent live picker entries. Additive schema-1 flag policy is documented, not a coordinated harness release.

## Regression coverage added (executed in continuation)

- `Agent/ProductionStatusTests.swift`: real dispatcher queued/grouped status, mixed completion, and cancellation through an injected executor.
- `Agent/ProductionRoutingTests.swift`: explicit I2V with storyboard/reference inputs, unavailable model rejection, camera tool round-trip and undo; local PNG with media-manifest registration.
- Continuation regressions: malformed camera scalars/objects fail without mutating the plan; an intervening manual plan edit prevents agent undo even when the action name matches.
- `Generation/CameraTrajectoryTests.swift`: boundaries, cumulative travel, advanced/legacy Codable, optional manifest flag, resolution and prompt defaults.
- `Generation/MiniMaxRequestTests.swift`: six final request bodies with injected catalog data, invalid combinations, inherited aspect, and recipe/submission propagation.
- Extended grouping and harness sidecar regressions. Importer scanning fixtures contain arbitrary tiny media bytes: they do not establish valid-media workflow integration.

## Actual checks

- `git diff --check`: passed during implementation; rerun before staging.
- Python JSON/source-data checks: bundled manifest parses; IDs unique; schema stays 1; global defaults match HEAD; Multi-Angle specification matches the sibling working tree.
- Sibling manifest SHA256 at inspection: `7ed44b0e3549b6b02c09e99700107741f510e939749382126364fe5559955541`.
- Continuation source checks corrected a hidden unsupported-camera state (visible Remove action), optional resolution JSON encoding (`null`), stale audio quote responses, camera inspector stale status, and explicit T2V discarding storyboard/reference inputs. Strict agent duration parsing now rejects fractional MiniMax seconds. Automatic grouped selection also refuses simple-prompt families.
- Replaced a PNG fixture with invalid IDAT CRC with a generated valid 1×1 RGB PNG. Python verified signature, every chunk CRC, and decompressed scanline. An NSImage decode assertion was added but has not run.
- `git diff --check` and manifest/default/spec checks rerun successfully after source review. These do not validate Swift syntax, actor isolation, or runtime behavior.
- Initial normal `swift build` executed and failed on three first-slice errors: two camera-array call sites passed `Any` into the dictionary-only decoder; the extracted main-actor request dictionary could not cross the async API boundary. Fixed the shared decoder to accept JSON values (including safely rejecting malformed scalar trajectories), and declared the newly constructed request result `sending`.
- `swift build`: passed after fixes (`Build complete! (16.36s)`). Existing warnings include HDR exporter captured progress variables, redundant `nonisolated(unsafe)` in caption preview, and redundant `await` in feedback code.
- `swift test --filter 'ProductionStatusTests|ProductionRoutingTests|CameraTrajectoryTests|MiniMaxRequestTests|MultiShotPlannerTests|HarnessProjectImporterTests|VideoPromptPreflightTests|ShotPromptBuilder|VideoModel.*Tests'`: 109 tests; one camera undo test failed with two assertions. This exposed a product gap: agent undo tracked timeline changes only. Extended the recorded snapshot to include the shot plan and checked it plus the undo action name before undoing.
- `swift test --filter 'ProductionStatusTests|ProductionRoutingTests|CameraTrajectoryTests|MiniMaxRequestTests|MultiShotPlannerTests|HarnessProjectImporterTests|VideoPromptPreflightTests|ShotPromptBuilder|VideoModel.*Tests|UndoToolTests'`: passed, 115 tests in 19 suites (0.028s test run; 12.53s build).
- `swift test`: passed, reported 1,058 tests in 165 suites (1.776s test run). Six model-dependent tests were skipped: `imageAndTextParity`, `indexesStillImage`, `padsAndTruncates`, `matchesPythonGoldens`, `undecodableFileGetsEmptyIndex`, and `indexAndSearchFixture`. Existing local H.264, XML/FCPXML, portable-project, and rendering tests passed; this is not the dated deterministic integration or native/live acceptance.
- Captured full-suite output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b013c2790014OTPL35dSsD0aH`. Successful build output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b010247e001qgngz6RdIssGfA`.

## Next slice and open gates

1. Phase 4 foundation: durable audio-line/role identities, idempotent partial reruns, measured lengths and timing ownership, linked native-audio keep/duck/mute restoration. Shared video finalization is now available through explicit `resume_production`; audio finishing remains separate.
2. Finish Phase 1 native verification of all six camera controls, unsupported-camera clear path, approval controls, inspector/retake/save-reopen, and 1080P budget presentation. The fixture rendered, but its background window on another Space exposes only menu-bar accessibility elements. Do not change the user's foreground app/Space to bypass this limitation.
3. Finish Phase 2 placement ownership: selection preview source windows, manually split descendants, arbitrary source replacement, and keep/duck/mute restoration. Exact retake/reset/dialogue addressing and linked replacement/reorder are covered below; these do not establish full production recovery.
4. Phases 3–5 remain open: revisioned QA/approval and dependency invalidation, attempt/quote ledger and stricter decoded-output validation, idempotent measured audio and exact-speech ownership, readiness, retained export jobs and verified immutable delivery.
5. Run the audit's valid-media 35–50s deterministic workflow and native manual-tweak acceptance before asking for a paid live budget. No exact-speech or live E2E claims until those lanes actually pass.

The original handoff remains the historical input. Continue from this report and the updated checklist; do not repeat the audit.

## Commit status

Historical attempt: staging using an explicit 47-file path list plus a related-only patch for `VeniceGeneration.swift` was rejected before execution by the approval reviewer (`ZodError`). No alternate index or indirect Git write was used. Continuation: normal Git writes work; committed first slice as `c36247d`, `feat(production): implement status and MiniMax camera routing contracts` (48 files).

Prepared staging inputs (outside the repository): `/tmp/venice-concept-to-export-paths` and `/tmp/venice-concept-to-export-request.patch`. The request patch passed `git apply --check --cached` before the permission request; that check does not write the index. Reinspect/regenerate those inputs if the tree changes. They intentionally omit the Seedance bitrate hunk from the proposed commit while retaining it in the working tree.

The first commit used 47 explicit whole-file paths and a refreshed request-builder patch; `git diff --cached --check` passed. The second catalog/1080P slice is committed as `fa3e067`, `fix(generation): guard catalog refreshes and budget 1080P attempts` (20 files), after staged-diff inspection. Storyboard approval is committed as `563608c`, `feat(production): bind storyboard approval to reviewed revisions` (20 files). Each commit excluded the unchanged Seedance bitrate block.

Native fixture/evidence is committed as `d9f2975`, `test(production): add native camera project fixture` (three files), with only the unrelated bitrate block left unstaged afterward.

Placement identity is committed as `f3542fb`, `fix(production): persist exact shot placement bindings` (13 files), after related-only staged review. The unrelated bitrate block remained unstaged.

Operation lifecycle is committed as `d0b4bc9`, `fix(production): persist attempts and guard cancelled operations` (16 files), with the unrelated bitrate block excluded.

## Catalog/1080P follow-up validation

- `ModelCatalog` now has an injected async loader. Superseded successful and failed loads cannot overwrite the latest state; a missing key clears the catalog. Reloading marks the catalog unavailable for new video submissions until it finishes.
- Native video selection uses model identity instead of an array index. Reordered lists keep the selected model; removed selections retain their visible identity and fail preflight. Current catalog constraints are consulted without silently choosing a different model.
- Automatic Multi-Angle resolution is 768P, or 480P when 768P is absent. An only-1080P catalog requires an explicit selection and cap. Nil-resolution requests serialize an allowed lower tier instead of relying on the provider's default.
- `VideoGenerationBudget` is per-request, in-memory authorization, deliberately absent from Codable recipes. Direct UI single/batch requests and production runs pass the same cap through submission/service/backend to the final runner. `generate_video`, `produce_shots`, and `regenerate_shot` expose `maxCostUSD`; native generation settings and the Production panel expose a USD cap field.
- Each 1080P send attempt obtains a new quote, checks finite positive cost and task cancellation, then atomically reserves within the shared cap. Parallel attempts/retries cannot each spend the full cap. Reservations are retained after attempted sends because billing on transport failure may be unknown. All new video sends recheck loaded/enabled catalog state after the quote. Resuming a known queue ID continues polling rather than making a new paid submission.
- Unbudgeted generic reruns fail in the shared service before reference preparation. Inspector actions with no new cap direct the user to the Production panel. Native UI operation, quote presentation, all-path valid-media integration, and save/reopen acceptance still require the dated manual/integration gates.
- This cap covers **only explicit Multi-Angle 1080P attempts**, not other lanes in a mixed production. It is not a durable operation ledger, billing reconciliation, or cancellation/restart proof. Production callbacks still have the pre-existing recovery limitations; ready panels still lack revision approval.
- Build iterations found and fixed the `reload()` return-value mismatch in the key observer and missing main-actor isolation on the test loader. These were compiler failures, followed by successful compilation.
- `swift test --filter 'ModelCatalogRaceTests|VideoGenerationBudgetTests|MiniMaxRequestTests|CameraTrajectoryTests|ProductionStatusTests|ProductionRoutingTests'`: passed, 32 tests in seven suites (0.015s tests; 18.28s build).
- `swift test`: passed, reported 1,070 tests in 167 suites (1.715s tests; 1.75s incremental build); same six model-dependent skips as the first full run. Combined captured output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b0291a22001AsjI2MyXwwq9KB`.
- `git diff --check`: passed after the follow-up. No paid/API/live catalog probes or native UI operation occurred.
- Additional files: `Generation/Catalog/ModelCatalog.swift`, `Generation/Catalog/VideoModelSelection.swift`, `Generation/GenerationBackend.swift`, `Generation/VideoGenerationBudget.swift`, `Generation/UI/VideoBudgetControl.swift`, and `Tests/VeniceVideoCreatorTests/Generation/{ModelCatalogRaceTests,VideoGenerationBudgetTests}.swift`; other follow-up edits are in the first-slice inventory below.

## Storyboard revision validation

- Added `Production/StoryboardReview.swift`: Codable panel revisions bind the asset ID, SHA256 of decodable image bytes, and sorted-JSON settings fingerprint. Panel reviews retain verdict, reviewer, summary, review date, approving identity/date, and override reason separately from the old take QA fields. Legacy `status=approved` is not panel approval.
- Shared plan mutation invalidates reviews when panel, camera, prompt, cast/location/reference settings, format, effective selected model, or prior same-location panel identity changes. Only dependent shots are invalidated; undo restores the prior matching revision. File-content changes at the same panel ID also fail validation.
- `qa_shot(artifact=storyboard)` explicitly selects the panel; passing QA can auto-approve that revision. Failed/unavailable QA cannot create panel approval. A deliberate native or user-via-agent approval records a nonblank reason and can override a failed/unchecked verdict. In-flight QA cannot approve an edited/replaced revision. Added an injected storyboard QA evaluator for no-provider dispatcher tests.
- Storyboard-bearing production checks approval at start/routing; single and grouped requests store revision bindings in `GenerationInput`/take recipes. The shared service checks before reference preparation, and a submission guard reaches the final runner before and after quoting. Already queued jobs continue their existing recovery path; this does not fix stale completion/placement callbacks or take QA.
- Native approval note/action controls added to `Inspector/ShotInspector.swift` and `Production/UI/ProductionPanel.swift`; `update_shots` supports `approveStoryboard` plus `approvalReason`. Agent instructions and storyboard hints now describe the gate.
- `swift test --filter 'StoryboardApprovalTests|ProductionRoutingTests|ProductionStatusTests|VideoGenerationBudgetTests'`: passed, 26 tests in four suites (0.028s tests, 19.87s build). An earlier compilation of the test helper needed an inner `try` in `#require`; fixed before successful runs.
- `swift test`: passed, reported 1,079 tests in 168 suites (1.719s tests, 1.87s incremental build), same six model-dependent skips. Captured combined output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b0434f5a001mUo79tahWz1BbU`.
- Regression cases use a decodable PNG and real dispatcher/editor mutations: legacy approval rejection, camera/override undo, selective canonical invalidation, failed QA/manual override, QA transport failure, stale async result, changed panel bytes, panel replacement/undo, and final-runner guard invocation before provider access. Codable round trip is not native save/reopen acceptance.
- `which cua-driver`, `cua-driver status`, `cua-driver check_permissions '{"prompt":false}'`: driver installed, daemon running, Accessibility and Screen Recording granted. `cua-driver list_apps` showed no running Venice app. No app was launched or native control driven in these prerequisite checks.
- Remaining scope: revision-bound **take** reviews and every grouped source range; failed/unavailable auto-QA placement; durable operations/recovery; revision protection for non-storyboard requests; decoded expected aspect; valid-media integrated workflow and actual native UI acceptance. Canonical-reference metadata/selection changes are fingerprinted; external same-ID replacement of canonical reference file bytes still needs dependency media revision tracking.

## Native fixture validation

- Added `Tests/VeniceVideoCreatorTests/Project/NativeCameraFixtureTests.swift`. The normal test writes/reads through `VideoProject` package I/O, checks the retained interior camera keyframe, and decodes the packaged image. An opt-in writer produces a retained fixture and refuses an existing destination.
- `VENICE_NATIVE_FIXTURE_PATH=/var/folders/sw/rpnndcqn6nlcdtbknm36s0fh0000gn/T/opencode/concept-to-export-native.venice swift test --filter NativeCameraFixtureTests`: passed, two tests. The package contains a valid 640×360 PNG, one image timeline clip, and a Multi-Angle shot with endpoints `(10,5,1)` and `(90,20,1.2)` plus the interior `(time:0.5,45,15,0.8)` keyframe.
- `swift test`: passed, reported 1,081 tests in 169 suites (1.714s tests, 2.02s incremental build). The six existing model-dependent tests and the opt-in retained fixture writer were skipped. Captured output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b053ff8d001m6x4VR4CxTngz3`.
- `bash scripts/bundle.sh debug`: built, bundled, and ad-hoc-signed `.build/Venice Video Creator.app`. Registered the bundle with LaunchServices and launched the retained project through `cua-driver launch_app`, bundle ID `ai.venice.studio`.
- App PID `12301`, fixture window `8800`, title `concept-to-export-native`: package restored one asset without missing media; screenshot showed the image and timeline. Screenshot: `/var/folders/sw/rpnndcqn6nlcdtbknm36s0fh0000gn/T/opencode/native-camera-initial.png`. Launch OSLog: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b0514370001L41uiJbwgWT00c`.
- Native interaction remains blocked: the fixture window was on Space `1`, while the current Space was `154`; `on_current_space=false`, `is_on_screen=false`. `get_window_state` exposed only 17 menu-bar AX elements. No camera/approval/budget control interaction, undo, retake, or native save/reopen was completed. The user's foreground app/Space was preserved.
- Launch performed normal free catalog/capability requests. No paid generation, fresh live lane probe, or verified live model availability is claimed. This small package is not the dated 35–50s integration film.

## Durable placement validation

- Added `Production/ShotPlacement.swift`: persisted video clip ID, linked native-audio clip IDs, asset ID, optional take/unit IDs, and assigned source window. Current manual trims/speed remain authoritative on the bound clips. `Shot` and `ShotTake` decode older packages with nil placement/range/unit fields. Placement metadata is excluded from storyboard settings fingerprints and preserved by agent plan resaves.
- Retakes, resets, dialogue start-frame lookup, and recovery use exact clip identity. A removed bound clip cannot silently adopt another use of its asset. Unique legacy shot/clip matches can be persisted on reopen; shared/ambiguous legacy matches fail with a reconciliation action. `update_shots` accepts `placedClipId`, including the shortened IDs returned by `get_timeline`, and rejects a clip already bound to another shot.
- Replacement preserves pair IDs, timeline position, edited source offsets/duration/speed, fades, and mix; insufficient replacement coverage fails before mutation. The selected `videoAssetId` changes with placement rather than when a candidate take is recorded. Grouped takes retain their per-beat source ranges and a shared unit ID; grouped placement rolls back fully on failure and supports one-operation undo/redo.
- Reset resolves all requested shots before modifying anything, removes the intended bound pair, retains deliberately unlinked audio, and restores plan/timeline together on undo. Native reset errors are surfaced as a toast; tool resets return errors instead of claiming success. Reordering uses exact clip IDs and moves linked partners; it rejects conflicting shared link groups and new overlaps with manual picture/audio edits.
- Recovery reuses an existing exact placement and rejects missing grouped legacy source ranges. Recovering watchers check the current shot/asset identity before acting. A local H.264 package round trip retains shared source ranges/clip IDs and repeated recovery does not duplicate already-bound clips. This does not validate reopen during upload/generation/download/QA or stale callbacks across cancellation/new runs.
- Added 12 regressions in `Tests/VeniceVideoCreatorTests/Agent/ShotPlacementTests.swift`: shared-asset middle reset/retake, pair edits and undo/redo, reversed completion and dialogue positions, explicit/ambiguous/shortened legacy binding, missing clip protection, too-short retake rejection, detached audio retention, manual audio collision, atomic grouped replacement, old decoding/resave, and actual package reopen. Most are metadata-level editor/dispatcher tests; the package case generates and probes a real local H.264 fixture.
- First package test exposed a fixture metadata mismatch: `MediaAsset` defaulted to audio-present for the silent fixture. The fixture now loads its actual audio tracks before placement. A later test tuple expression exceeded Swift's type-check limit; split and typed the expression. Both were corrected before successful final runs.
- `swift test --filter 'ShotPlacementTests|ProductionRoutingTests|ProductionStatusTests|StoryboardApprovalTests'`: passed, 30 tests in four suites (0.198s tests, 4.80s incremental build).
- `swift test`: passed, reported 1,093 tests in 170 suites (1.805s tests, 2.03s incremental build). Same seven skips as native fixture validation. Combined output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b06f3b5d001RNwB29K3G7qExF`.
- Final source review added `placedClipId` to the input prefix resolver and changed the repair regression to pass the actual short ID. `swift test --filter 'ShotPlacementTests|ShortIdTests'`: passed, 18 tests in two suites (0.176s tests, 10.85s build), after that change. No paid/API/native interactions in this slice.
- Remaining: pre-wait durable operation/line identities and job stages; exactly-once finalization with validation/QA; cancellation/restart callbacks; split-descendant and selection-preview ownership; keep/duck/mute restoration; revisioned take/range QA; measured idempotent audio; retained verified export. Group unit IDs here are assigned when recording a completed take, not durable pre-submission operation IDs.
- Related paths: `Production/{ShotPlacement,ShotPlan,ProductionOrchestrator,StoryboardReview}.swift`, `Editor/ViewModel/EditorViewModel+{GeneratedClips,ShotPlan}.swift`, `Agent/Tools/{ToolDefinitions,ToolExecutor+ShotPlan,ToolExecutor+ProduceAudio,ToolExecutor+ShortId}.swift`, the new tests, and both dated progress records. The unrelated `VeniceGeneration.swift` bitrate block remains excluded.

## Production operation lifecycle validation

- Added `Production/ProductionOperation.swift`. The manifest retains operation/run IDs, shot setting digests and destination placements, QA policy, stage, attempts, per-attempt stable take IDs, pre-upload recipes, placeholders, backend/remote queue IDs, generation status, and failure reasons. Older manifests decode an empty operation array. These records survive shot-plan resaves and media-library undo; shot runtime operation bindings are excluded from storyboard fingerprints.
- Single-shot operations are recorded and checkpointed before frame chaining or quotes. Group operations are recorded before their first asynchronous quote. Attempts and take IDs are created before submission; the shared generation service associates the actual placeholder and awaits another checkpoint before reference preparation. Native `VideoProject` supplies an awaited autosave callback; missing/closed/unsaved projects and checkpoint errors stop production before provider access. Native autosave callback behavior has compiled but still needs native acceptance.
- Submission validates the current run, operation, latest attempt, shot settings, and destination again at the final runner's existing submission guard, including its post-quote check. Unit tasks are owned/cancelled; production checks operation identity after generation, output validation, and QA waits. A cancelled old callback cannot place, record a late take, overwrite current QA, or increment the new run's counters. `runningUSD` resets for each run; it still measures accepted quoted outputs rather than reconciled total billing.
- Take IDs are assigned before generation and reused when recording the result; grouped `productionUnitId` is now the pre-wait operation ID. `production_status` includes a total operation count and the latest 50 compact operation summaries without recipes/reference payloads. Backend completion can still update its own attempt metadata after production stops, preserving the actual remote outcome.
- Failed or unavailable auto-QA now stops placement when retries are exhausted; a QA outage retains the generated take without buying another one. This fixes the previous unchecked/failed fallthrough but does not establish revision-bound take reviews or per-range QA for every grouped beat.
- Reopen holds interrupted operation-backed shots for review, preserving the operation and assets. Existing generation service queue/download recovery remains separate; no new paid request or automatic placement is initiated by production reconciliation for these operations. Legacy recovery is blocked from acting on a shot now owned by a new operation. A shared validated/QA-aware live/recovered finalizer is the next implementation gate.
- Added 11 tests in `Agent/ProductionOperationTests.swift`, using the real production loop with injected catalog, quote, generation, validation, QA, and checkpoint boundaries: pre-provider operation/take identity, late completion/validation/QA across Stop→Start, edits during checkpoint, failed/unavailable QA at retry limit, distinct retry identities, actual service placeholder checkpoint failure, interrupted package round trip, cancelled checkpoint failure, and ledger retention through media-library undo. Provider outputs in these lifecycle tests are metadata fixtures; the earlier placement package test supplies real H.264 coverage.
- `swift test --filter 'ProductionOperationTests|ProductionStatusTests|ShotPlacementTests|StoryboardApprovalTests'`: passed, 36 tests in four suites (0.293s tests, 16.95s build).
- `swift test`: passed, reported 1,104 tests in 171 suites (1.894s tests, 2.24s incremental build). Same seven skips. Combined output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b0e38bc5001gRGBnZc6qU9ADx`.
- Final source review preserved specific provider/checkpoint failure details instead of overwriting them with a generic generation failure. `swift test --filter ProductionOperationTests`: passed, 11 tests in one suite (0.024s tests, 13.70s build) after that change. No paid/API/native interactions in this slice.
- Remaining: shared recovered finalization and explicit resume/review actions; durable audio-line records; decoded output dimensions/aspect and QA revision/range evidence; total attempt/cost reconciliation; unknown-billing transport retry policy; native checkpoint/error/reopen operation; the dated full workflow acceptance. Pre-submit checkpoint snapshots are tested through injection and package I/O, not crash-injected native autosave.
- Related files: `Production/{ProductionOperation,ProductionOrchestrator,ProductionStatus,ShotPlan,StoryboardReview}.swift`, `Models/MediaManifest.swift`, `Generation/GenerationService.swift`, `Project/VideoProject.swift`, `Editor/ViewModel/{EditorViewModel,EditorViewModel+ShotPlan,EditorViewModel+Folders}.swift`, `Agent/Tools/ToolExecutor+{Production,ShotPlan}.swift`, the new lifecycle tests, and both dated records. `VeniceGeneration.swift` remains excluded.

## Shared live/recovered finalization validation

- Added `Production/ProductionFinalization.swift`. Live single/grouped production and explicit recovery use the same finalizer. It records streamed SHA256 video identity, validation outcome/date, each beat's source range and reviewer/verdict/date, any human approval reason, and the resulting exact placements on the persisted attempt. Existing passed ranges are reused only for the same asset/content digest/range; changed bytes require fresh review. A final digest check detects video changes during QA.
- Operation destinations now retain planned seconds and the approved storyboard revision, and operations retain the plan seed. Changed seed, panel revision, shot settings, or destination blocks finalization. Group coverage must reach the planned total within one timeline frame; the last beat cannot absorb a material duration deficit. Legacy operations lacking saved beat timing fail with a reconciliation action rather than guessing ranges.
- `resume_production(operationId, approvalReason?)` and native **Finish existing take → Validate and Finish / Approve Take** act on the latest retained attempt. The tool accepts short IDs. Approval reasons are explicit, nonblank, and recorded separately from the underlying failed/unchecked QA result; manual approval avoids another QA call. Hard media-validation failures cannot be overridden. Generation submission/quoting is absent from this path; automatic QA can still use its configured vision model.
- `VisionQA.videoFrames` now accepts an explicit source range and uses zero extraction tolerance for range-scoped review. Every grouped beat gets its own rubric/frame samples. The selected reviewer is captured with the QA request. `production_status` exposes the digest and per-beat review summaries. Agent instructions describe finishing retained attempts and remove the inaccurate claim that a single grouped render cannot drift.
- One attempt is locked against concurrent finalization. Completed operations are idempotent while their exact placements still exist; undo/removal is not silently reversed by another resume. A failed post-placement checkpoint remains actionable and is not counted as success; retry saves the existing placements without duplicating them. Existing take IDs prevent duplicate take history during QA retries/reopen.
- Explicit recovery invokes the existing generation-service queue/download resumer for the selected asset. Active local generation tasks are not monitored twice, and settled failed/cancelled jobs with persisted handles use queue/result recovery rather than re-observing a terminal local publisher. The finalizer waits only while generation is active, then requires a ready asset. Actual server polling/download retry has not been exercised live in this slice.
- Output validation now rejects non-finite decoded dimensions/duration and property-probe failures instead of passing on read errors. The default finalizer refreshes measured duration from the actual video before planning source ranges. MiniMax inherited expected aspect comes from decoding the saved original first frame, not the omitted API aspect field. Exact ratio tolerances and requested resolution floors remain open.
- Submission hardening: an attempt can bind only one placeholder; a generic replay of its recipe cannot overwrite the original job record or reach provider submission through a second placeholder. New attempts are refused while the preceding one is finalizing. The service checks placeholder identity before reference preparation and at the final submission guard.
- Added 13 tests in `Agent/ProductionFinalizationTests.swift`: per-beat review, cached-range reuse, manual override, changed-content rejection, seed mismatch, final-checkpoint retry, undo protection, package reopen, concurrent/cancelled finalization, decoded first-frame aspect, non-finite validation facts, and grouped duration coverage. A real two-color H.264 verifies frame samples stay inside the requested beat; a byte edit verifies the real streamed hash changes. The main finalization fixtures inject provider/QA/validation/digest boundaries and do not certify a full rendered film.
- Extended `ProductionOperationTests` with final-checkpoint failure accounting and second-placeholder replay rejection. The new explicit-undo fixture initially terminated with `NSUndoManager`'s missing-group exception; added explicit synchronous groups around asynchronous take/QA record mutations. Subsequent targeted and full runs passed.
- `swift test --filter 'ProductionFinalizationTests|ProductionOperationTests|ProductionStatusTests|StoryboardApprovalTests|OutputValidatorTests'`: passed, 46 tests in five suites (0.219s tests, 19.95s build).
- `swift test`: passed, reported 1,118 tests in 172 suites (1.700s tests, 1.84s incremental build), same seven skips. Combined output: `/Users/venetian42069/.local/share/opencode/tool-output/tool_0b1122af0001j9pUeYQT2fuBQe`.
- `swift build`: passed (7.32s) after the final agent-instruction update. Final review corrected failed→unavailable QA reporting so a transport outage cannot inherit the previous failed verdict; `swift test --filter 'ProductionFinalizationTests|ProductionOperationTests'` passed afterward, 25 tests in two suites (0.211s tests, 11.48s build).
- Native finish/approval controls, awaited native autosave failure/reopen, real queue/download recovery, and the dated 35–50s integration remain open. Same-ID external canonical-reference byte replacement, standalone `qa_shot` take evidence, review invalidation after arbitrary timeline edits, older-take selection, resolution floors/exact aspect checks, total billing reconciliation, durable audio finishing, and retained verified export remain open. No new native, paid, or live API operation was performed by this slice.
- Related paths: `Production/{ProductionFinalization,ProductionOperation,ProductionOrchestrator,ProductionStatus,OutputValidator,VisionQA}.swift`, `Production/UI/ProductionPanel.swift`, `Generation/GenerationService.swift`, `Agent/Tools/{AgentInstructions,ToolDefinitions,ToolExecutor,ToolExecutor+Production,ToolExecutor+ShortId}.swift`, both production lifecycle/finalization test files, and these dated records. `VeniceGeneration.swift` remains excluded.

## Changed-file inventory

Related inherited and implementation files present at this stopping point (the request-builder file additionally contains the excluded bitrate hunk):

- `.cursor/rules/harness-app-capability-sync.mdc`
- `Sources/VeniceVideoCreator/Agent/Tools/AgentInstructions.swift`
- `Sources/VeniceVideoCreator/Agent/Tools/ToolDefinitions.swift`
- `Sources/VeniceVideoCreator/Agent/Tools/ToolExecutor+Generate.swift`
- `Sources/VeniceVideoCreator/Agent/Tools/ToolExecutor+Production.swift`
- `Sources/VeniceVideoCreator/Agent/Tools/ToolExecutor+ShotPlan.swift`
- `Sources/VeniceVideoCreator/Agent/Tools/ToolExecutor.swift`
- `Sources/VeniceVideoCreator/App/MainMenu.swift`
- `Sources/VeniceVideoCreator/Editor/EditorWindowController.swift`
- `Sources/VeniceVideoCreator/Editor/ViewModel/EditorViewModel+ShotPlan.swift`
- `Sources/VeniceVideoCreator/Generation/Catalog/CapabilityManifest.swift`
- `Sources/VeniceVideoCreator/Generation/Catalog/VideoModelCapabilities.swift`
- `Sources/VeniceVideoCreator/Generation/Catalog/VideoModelConfig.swift`
- `Sources/VeniceVideoCreator/Generation/GenerationService.swift`
- `Sources/VeniceVideoCreator/Generation/Submission/VideoGenerationSubmission.swift`
- `Sources/VeniceVideoCreator/Generation/UI/GenerationView.swift`
- `Sources/VeniceVideoCreator/Inspector/ShotInspector.swift`
- `Sources/VeniceVideoCreator/Models/MediaManifest.swift`
- `Sources/VeniceVideoCreator/Production/MultiShotPlanner.swift`
- `Sources/VeniceVideoCreator/Production/ProductionOrchestrator.swift`
- `Sources/VeniceVideoCreator/Production/ShotPlan.swift`
- `Sources/VeniceVideoCreator/Production/ShotPromptBuilder.swift`
- `Sources/VeniceVideoCreator/Production/UI/LocationsPanel.swift`
- `Sources/VeniceVideoCreator/Production/UI/ProductionPanel.swift`
- `Sources/VeniceVideoCreator/Resources/Capabilities/capabilities.json`
- `Sources/VeniceVideoCreator/Venice/VeniceAPI.swift`
- `Sources/VeniceVideoCreator/Venice/VeniceGeneration.swift`
- `Sources/VeniceVideoCreator/Venice/VeniceModel.swift`
- `Tests/VeniceVideoCreatorTests/Agent/VideoPromptPreflightTests.swift`
- `Tests/VeniceVideoCreatorTests/Generation/MultiShotPlannerTests.swift`
- `Tests/VeniceVideoCreatorTests/Generation/ShotPromptBuilderTests.swift`
- `Tests/VeniceVideoCreatorTests/Generation/VideoModelCapabilitiesTests.swift`
- `AUDIT-concept-to-export-2026-09-17.md`
- `HANDOFF-concept-to-export-2026-09-17.md`
- `PLAN-concept-to-export-2026-09-17.md`
- `Sources/VeniceVideoCreator/Editor/ViewModel/EditorViewModel+HarnessImport.swift`
- `Sources/VeniceVideoCreator/Generation/CameraTrajectory.swift`
- `Sources/VeniceVideoCreator/Generation/MiniMaxVideoContract.swift`
- `Sources/VeniceVideoCreator/Generation/UI/CameraMoveControls.swift`
- `Sources/VeniceVideoCreator/Production/HarnessProjectImporter.swift`
- `Sources/VeniceVideoCreator/Production/ProductionModelSelection.swift`
- `Sources/VeniceVideoCreator/Production/ProductionStatus.swift`
- `Tests/VeniceVideoCreatorTests/Agent/ProductionRoutingTests.swift`
- `Tests/VeniceVideoCreatorTests/Agent/ProductionStatusTests.swift`
- `Tests/VeniceVideoCreatorTests/Generation/CameraTrajectoryTests.swift`
- `Tests/VeniceVideoCreatorTests/Generation/MiniMaxRequestTests.swift`
- `Tests/VeniceVideoCreatorTests/HarnessProjectImporterTests.swift`
- `VALIDATION-concept-to-export-2026-09-17.md`

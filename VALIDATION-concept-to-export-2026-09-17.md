# Concept-to-export implementation validation

Date: 2026-09-17
Status: routing `c36247d`, catalog/1080P `fa3e067`, and storyboard approval `563608c` committed. Native fixture package round trip and launch verified; native control acceptance remains blocked. Not E2E-ready.

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

1. Retain the validated native fixture and evidence in a separate commit, excluding the unrelated Seedance bitrate block. Routing `c36247d`, catalog/1080P `fa3e067`, and storyboard approval `563608c` commits exist.
2. Finish Phase 1 native verification of all six camera controls, unsupported-camera clear path, approval controls, inspector/retake/save-reopen, and 1080P budget presentation. The fixture rendered, but its background window on another Space exposes only menu-bar accessibility elements. Do not change the user's foreground app/Space to bypass this limitation.
3. Phase 2: durable shot-to-clip/source-range/linked-audio bindings, stable pre-wait operation and line IDs, exactly-once live/recovered finalization. Replace asset-only retake/reset/dialogue lookup and linked-group mutation before claiming production recovery.
4. Phases 3–5 remain open: revisioned QA/approval and dependency invalidation, attempt/quote ledger and stricter decoded-output validation, idempotent measured audio and exact-speech ownership, readiness, retained export jobs and verified immutable delivery.
5. Run the audit's valid-media 35–50s deterministic workflow and native manual-tweak acceptance before asking for a paid live budget. No exact-speech or live E2E claims until those lanes actually pass.

The original handoff remains the historical input. Continue from this report and the updated checklist; do not repeat the audit.

## Commit status

Historical attempt: staging using an explicit 47-file path list plus a related-only patch for `VeniceGeneration.swift` was rejected before execution by the approval reviewer (`ZodError`). No alternate index or indirect Git write was used. Continuation: normal Git writes work; committed first slice as `c36247d`, `feat(production): implement status and MiniMax camera routing contracts` (48 files).

Prepared staging inputs (outside the repository): `/tmp/venice-concept-to-export-paths` and `/tmp/venice-concept-to-export-request.patch`. The request patch passed `git apply --check --cached` before the permission request; that check does not write the index. Reinspect/regenerate those inputs if the tree changes. They intentionally omit the Seedance bitrate hunk from the proposed commit while retaining it in the working tree.

The first commit used 47 explicit whole-file paths and a refreshed request-builder patch; `git diff --cached --check` passed. The second catalog/1080P slice is committed as `fa3e067`, `fix(generation): guard catalog refreshes and budget 1080P attempts` (20 files), after staged-diff inspection. Storyboard approval is committed as `563608c`, `feat(production): bind storyboard approval to reviewed revisions` (20 files). Each commit excluded the unchanged Seedance bitrate block.

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

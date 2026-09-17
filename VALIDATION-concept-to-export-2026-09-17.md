# Concept-to-export implementation validation

Date: 2026-09-17
Status: first implementation slice compiled and regression-tested; related-only commit preparation in progress. Not E2E-ready.

## Permissions and spending

- The user explicitly authorized normal Swift build/tests (including compiler-cache writes) and Git staging/commit. Earlier retries were rejected before execution by the automatic approval reviewer (`ZodError`). The continuation environment now executes normal `swift build` and `swift test` successfully. No alternate caches, indirect builds, or tests were used to bypass a denial.
- No paid requests, fresh live catalog/quote probes, or native UI runs. Existing local export regression tests ran as part of the full suite; the dated concept-to-export acceptance fixture has not run.
- Sibling harness was read only. Its uncommitted Multi-Angle contract is local evidence, not evidence of publication. No sibling files were changed.

## Preserved work and implemented scope

- Related inherited changes retained: Max/Turbo manifest/capabilities/prompts/tests, harness import and menu/window integration, source metadata, canonical character/location reference selection, and sync policy. Unrelated request-body change flagged for later: the Seedance 2.5 `bitrate_mode: "high"` block in `Venice/VeniceGeneration.swift` is preserved in the working tree and excluded from the proposed commit. Its origin is not established by the continuation summary; no claim is made that it is verified or required by this slice.
- F01: typed JSON production status with flattened shot IDs, queued shot/unit counts, nullable state, separate success/failure/cancellation/settled/pending accounting, and explicit encoding failure. The injected unit executor supports no-provider dispatcher regression tests. Run identity guards prevent old loop cleanup from replacing new run counters; unstructured in-flight production tasks/callbacks still need cancellation/restart and durable recovery work, so old callbacks are not proven safe against a new run.
- F02: resolve selected shot/default IDs before automatic routing; reject unavailable selections; storyboard/chained frames route to I2V, references to R2V, no visuals to T2V when automatic. Inherited MiniMax I2V aspect is omitted from provider requests/quotes. Ready frames are not yet revision-approved frames: approval gates remain open.
- Shared Codable camera array and validator, shot/generation/recipe/import persistence, agent schema and patch support, six accessible endpoint controls, and final request serialization. Advanced interior keyframes survive endpoint edits; reset deliberately replaces the path. Durable operations and full project recovery still require Phase 2.
- Exact Multi-Angle capability handling, automatic 768P, simple prompts, optional Multi-Angle prompt, and no camera grouping. Max simple-prompt grouping is disabled. Full-plan adjacency blocks grouping a subset across omitted shots.
- Strict six-lane MiniMax request contract: duration/resolution, image/reference lanes, inherited aspect, omitted native-audio toggle, and early invalid-input rejection. Explicit 1080P has UI quote refresh but not yet a mandatory fresh-quote/budget gate on every submission path.
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

1. Inspect the staged diff and commit the validated related first slice. Normal build/test execution is established; preserve the unrelated Seedance bitrate block outside the commit.
2. Finish Phase 1 validation: model/catalog load races, native verification of the unsupported-camera clear path, required fresh 1080P quote authorization, six-lane fixtures, inspector undo/retake/save/reopen, and explicit revision-approved storyboard routing.
3. Phase 2: durable shot-to-clip/source-range/linked-audio bindings, stable pre-wait operation and line IDs, exactly-once live/recovered finalization. Replace asset-only retake/reset/dialogue lookup and linked-group mutation before claiming production recovery.
4. Phases 3–5 remain open: revisioned QA/approval and dependency invalidation, attempt/quote ledger and stricter decoded-output validation, idempotent measured audio and exact-speech ownership, readiness, retained export jobs and verified immutable delivery.
5. Run the audit's valid-media 35–50s deterministic workflow and native manual-tweak acceptance before asking for a paid live budget. No exact-speech or live E2E claims until those lanes actually pass.

The original handoff remains the historical input. Continue from this report and the updated checklist; do not repeat the audit.

## Commit status

Historical attempt: staging using an explicit 47-file path list plus a related-only patch for `VeniceGeneration.swift` was rejected before execution by the approval reviewer (`ZodError`). No alternate index or indirect Git write was used. Continuation: build and tests now pass; related-only staging and commit are being prepared in the functioning environment.

Prepared staging inputs (outside the repository): `/tmp/venice-concept-to-export-paths` and `/tmp/venice-concept-to-export-request.patch`. The request patch passed `git apply --check --cached` before the permission request; that check does not write the index. Reinspect/regenerate those inputs if the tree changes. They intentionally omit the Seedance bitrate hunk from the proposed commit while retaining it in the working tree.

Next action: stage explicit reviewed paths plus a refreshed request-builder patch including the compiler fix and excluding the bitrate block; inspect the complete staged diff, then commit. Do not label it full concept-to-export completion.

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

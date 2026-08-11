# Audit — Creator app agentic work vs venice-video-harness

2026-08-07. Baseline: harness v2.15.0 (`9b32370`), app branch `venice-integration`.
Question: does agentic work inside the app do what the harness does — and beyond —
populating the timeline and panes with references, prompts, and assets?

## Verdict

The port is real and current. The app covers the harness's production loop
(plan → characters/locations → storyboard → produce → QA → place), and goes
beyond it in the ways that matter for an editor: shots land as timeline clips,
cast/locations/shot-plan are visible panes, regeneration replaces clips
in place. Capability manifests are byte-identical (harness 2.15.0 snapshot,
schemaVersion 1, generated 2026-08-05). The gaps that remain are mostly the
harness's newest consistency machinery (@Image slot binding, blocking plates,
recipe sidecars) and audio assembly rigor (measured-duration no-overlap
scheduler). Detail below.

## 1. What's at parity (verified in code)

| Harness capability | App equivalent | Where |
|---|---|---|
| Shot script (`script.json`) | `ShotPlan` in MediaManifest + markdown mirror in Documents tab | `Production/ShotPlan.swift`, `EditorViewModel+ShotPlan.swift` |
| Character refs + locked voice | `create_character` / `audition_voices` / `lock_voice`; Cast & Objects pane with reference thumbs | `ToolExecutor+Character.swift`, `Production/UI/CastPanel.swift` |
| Location 3-angle ladder (wide/medium/detail) + `spatialAnchors` baked into every angle (rule 49) | `create_location` generates the same ladder; anchors clause in each angle prompt; Locations pane | `ToolExecutor+Location.swift`, `Production/UI/LocationsPanel.swift` |
| Blocking + spatial anchors in video prompts (rule 49) | `Blocking:` + `Fixed layout (never rearrange):` + no-mirroring clause restated per take | `ShotPromptBuilder.videoPrompt` |
| Reference slot planner tiers + overflow policy (rule 42) | Tiered stack: identity (protected) → shot's storyboard panel (protected) → location ladder → extra char angles; overflow drops bottom-up | `ProductionOrchestrator.route()` ~749–795 |
| Seedance native multi-shot, `Lens switch.` separators (rules 18/21) | `MultiShotPlanner` ports `generation-planner.ts` 2.13.0 gates: pairwise character overlap, same location, ≤15s/6 shots, VO shots excluded, fade boundaries kept | `Production/MultiShotPlanner.swift` |
| Multi-shot unit → per-beat placement | Unit video split into per-shot timeline clips at beat boundaries, last shot absorbs surplus | `placeUnitClips()` |
| Vision QA incl. SPATIAL CONTINUITY dimension (rule 49d) | Rubric checks blocking/fixed-layout; spatial flip = fail; auto-QA can trigger a retake | `Production/VisionQA.swift` ~136, `runAutoQA` |
| VO prompt rules (`03a17f4`) | VO lines never reach video prompt; suppression line appended | `ShotPromptBuilder` |
| Voice references on dialogue shots (rule 40) | Shot audio ref, else character's locked `voiceReferenceAssetId`, only on `maxReferenceAudios > 0` models | `voiceAudioReference()` |
| Frame chaining (dissolve/match-cut) | `chainStartFrame` → i2v seed when no character refs | `produceOne` / `route` |
| Quote-before-queue, retries, Seedance consent, duration snap/refuse | Quote posted per shot with cost; retry ladder; consent gate; overlong shots refuse rather than truncate | `produceOne` |
| Job resume by queue_id (rule 43) | `VeniceGeneration.resume(queueId:)`, orchestrator `resume(editor:)` reconciles stuck shots on reopen | `VeniceGeneration.swift`, plan post-port fixes |
| Capability manifest (2.15.0) | Bundled snapshot byte-identical to harness `capabilities.json`; schema-gated; optional auto-refresh from GitHub raw | `CapabilityManifestStore` |
| Provenance (`hasFace`, edit lineage) | `GenerationInput` + sidecar fields carried through edit paths | `MediaManifest.swift` |

Beyond the harness: everything lands somewhere visible. Shots → production
video track (plan-ordered, regeneration replaces in place); dialogue/music/
ambient → placed audio clips; panels → linked per-shot in the Production
panel; characters/locations → dedicated panes with thumbnails; the plan →
a live markdown document. Prompts, model, duration, reference asset ids,
and queue id are recorded per asset in `GenerationInput` — inspectable via
the media panel. The harness's WORKSHOP.html treatment page is effectively
superseded by these live panes (the app IS the live document).

## 2. Gaps — harness does it, app doesn't (ranked)

### High impact (consistency of paid renders)

1. **No `@ImageN` tag binding.** The harness's rule 42 core: prompt indices
   and `reference_image_urls` push order come from ONE slot list, with
   per-slot role clauses ("@Image1 is Bob", "@Image5 is a second angle of
   the courtyard"). The app sends the same tiered ref stack but identity is
   carried by character *names* in prose (`MultiShotPlanner.swift:121-123`
   says so explicitly). On Seedance R2V the untagged stack is materially
   weaker — the model guesses which ref is whom. This is the single
   biggest consistency delta.
2. **No storyboard blocking plates.** The harness generates a per-beat
   composed plate (`storyboard-reference-generator.ts`, PROTECTED slot,
   "use ONLY for composition") — the app substitutes the shot's storyboard
   panel, which is close but is a *panel* (has character likeness baked
   in) not a neutral blocking plate, and multi-shot units only take the
   window's FIRST panel (`routeUnit` ~499), so later beats have no
   composition anchor.
3. **No negative prompts at all.** Zero occurrences in the app's video
   path. The harness appends the music/SFX suppression negative (rule 33)
   and anti-realism/film-burn negatives per lane. The app steers audio
   content positively (`audioContent` clauses) which is partial cover, but
   there is no negative_prompt field on `GenerationInput` and none sent.
4. **No dialogue no-overlap scheduler (rules 35/36, anti-pattern 19).**
   `produce_audio` places dialogue at `estimateSpeechSeconds` (words/2.7)
   offsets from the shot's start — the exact planned-not-measured bug the
   harness documents. Placeholder clips are later resized to real duration
   (`finalizeGeneratingClip`) but their START positions never re-flow, so
   consecutive lines can overlap once real durations land. No global
   cursor, no measured-duration pass, no hold-frame extension.

### Medium impact

5. **No recipe sidecars (rule 39).** `GenerationInput` records prompt/
   model/refs/queueId for the LAST pass, but there's no append-only
   replayable pass log, no role tagging (content/identity/look), no
   seed/cfg recorded (the app never sets seeds at all — the harness locks
   series seeds for reproducibility).
6. **`fix_panel` is single-image `/image/edit`, not multi-edit with
   character refs** (flagged in the port plan itself). Character-drift
   panel fixes can't re-anchor to the cast.
7. **No Seedance→Wan keyframe lip-sync strategy (rule 32)** — deliberately
   deferred; building blocks exist (`LastFrameExtractor`,
   `AudioSilencePadder`, `audioInputCapable`) but no route picks them.
8. **Storyboard is one pass.** No pass-2 multi-edit refine, no
   lighting style-match against the previous same-location panel
   (anti-pattern 7), no first-frame contact-sheet drift check.
9. **QA coverage.** VisionQA samples 3 frames/shot; there's no episode-level
   cut-qa (audio pop, VO truncation, dialogue overlap assertion at
   boundaries), and no "errored ≠ passed" distinction (rule 46b) — a QA
   call that throws returns nil and the shot proceeds as if unchecked.

### Low impact / deliberate

10. **Editing pipeline text-first EDL loop** — the app has transcription,
    `remove_words`, captions, `ripple_delete_ranges` (arguably a better
    interactive equivalent), but no takes_packed.md/EDL/cut-qa self-eval.
    Deferred by design; the timeline replaces the EDL.
11. **`elements[]` / `scene_image_urls` builders** — hard-off pending live
    probe (correct per the sync rule).
12. **Multi-shot grouping default:** harness defaults multi-shot ON
    (rule 18); app is opt-in off (`multiShotGroupingEnabled`) under its
    non-regression rule. Fine, but worth surfacing in-app so users know
    the cheaper/more-consistent lane exists.
13. **Music bed looping/ducking under VO** — beds span the edit but no
    auto-duck under dialogue windows (plan Phase 4 remainder).

## 3. Live bugs already on file (not re-audited)

- HTTP 413 on heavy production runs (`HANDOFF-agent-413.md`) — RC1–RC4
  confirmed in code; fix combination B+A+E+C recommended there.
- `wait_for_media` "asset not found" registration lag right after
  `storyboard_shots` (same handoff, secondary bug).

## 4. Recommended order of work

1. `@ImageN` slot binding (gap 1) + negative_prompt plumbing (gap 3) —
   both are prompt/request-body changes inside the existing tiered-stack
   code path; highest consistency return per line of code. Gate the
   negative behind the non-regression flag pattern.
2. Dialogue scheduler re-flow on finalize (gap 4) — reuse the global-cursor
   algorithm from harness rule 35; the measured duration is already in
   hand at `finalizeGeneratingClip` time.
3. `fix_panel` → multi-edit with character refs (gap 6).
4. Recipe pass log (gap 5) — extend `GenerationInput` to an array of
   passes; unlocks honest regeneration and the finishing convention.
5. Blocking plates (gap 2) as an optional pre-produce step, then the
   lip-sync strategy (gap 7) once the produce loop has mileage.

## 5. Sync hygiene notes

- `capabilities.json`: app bundle byte-identical to harness @2.15.0 ✅.
- Keep obeying `.cursor/rules/harness-app-capability-sync.mdc` — the
  Wan 2.7 set-drift case shows the harness's two layers can disagree;
  the app's bundled-snapshot test is the tripwire.
- Harness rules 44/45 (status reporter mirrors gates) have an app analog:
  `AgentInstructions` describes the workflow gates — when a ToolExecutor
  gate changes (e.g. the storyboard cast-refs hard gate), update the
  instructions text in the same commit.


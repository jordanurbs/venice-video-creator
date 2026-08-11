# HANDOFF: Harness parity fixes — Creator app agentic production

**Date:** 2026-08-07 · **Source:** audit vs `~/projects/tools/venice-video-harness/` (2.15.0);
full findings in `AUDIT-harness-parity-2026-08-07.md` (read it first — this handoff is the
fix list, that doc is the evidence).
**Verdict:** the port is architecturally sound and in several ways *beyond* the harness
(live timeline placement, parallel units, take history, queued runs). The gaps below are
ordered by impact. Fix top-down; each item is self-contained.

## Context — what already matches (don't re-do)

- Capability manifest sync is live and IDENTICAL (`capabilities.json` repo root ↔
  `Sources/VeniceVideoCreator/Resources/Capabilities/capabilities.json`, schemaVersion 1).
- Tiered reference stack (identity → storyboard panel → location angle ladder → extra
  character angles, overflow drops bottom-up) is ported in `ProductionOrchestrator.route()`
  and `routeUnit()`.
- Multi-shot grouping (rule 21) ported in `MultiShotPlanner` (opt-in, gates mirror
  `canUseMultiShotWindow`, `Lens switch.` separators, per-beat blocking, geometry hold).
- Spatial consistency (rule 49): `LocationSpec.spatialAnchors` + `Shot.blocking`, injected
  into prompts + QA rubric. Location 3-angle ladder (wide/medium/detail) with anchors baked
  into every angle.
- Characters/objects with locked refs, voice audition/lock, auto voice-reference
  (rule 40 equivalent), VO suppression rule (03a17f4), face provenance (`hasFace`,
  `editModels`), Seedance consent gate, queue_id relaunch resume (`GenerationInput.queueId`).
- Frame chaining on dissolve/matchCut; per-shot quote-before-queue; markdown Shot Plan
  mirror in Documents tab; Production panel + Cast/Locations tabs.

---

## P0 — correctness bugs in shipped behavior

### 1. `produce_audio` dialogue lands at frame 0 for unplaced shots + no overlap scheduler (harness rules 35/36, anti-pattern 19)

`ToolExecutor+ProduceAudio.swift`:
- `shotStartFrame()` returns **0** when a shot has no placed clip — every dialogue line
  for unplaced shots piles up at the head of the timeline.
- Line placement uses `estimateSpeechSeconds` (words/2.7) to advance `offsetFrames`
  WITHIN a shot, but there is **no global no-overlap cursor across shots/speakers**.
  The harness learned this the hard way: schedule ALL spoken lines (narrator + character)
  against ONE `nextFree` cursor with a small gap, using MEASURED durations, never planned.
- The estimate is never corrected after the real clip lands: `finalizeGeneratingClip`
  resolves the asset but does not re-place subsequent lines whose starts were derived
  from the estimate.

**Fix:** (a) skip dialogue for unplaced shots (or place after `produce_shots` completes,
which is the harness order — document that in AgentInstructions); (b) single global
cursor: `placeStart = max(shotStart + lead, nextFree + gapFrames)`, advance by the real
duration on finalize; (c) on finalize, if the measured clip overruns into the next line,
ripple the later dialogue clips (they're all on the dialogue lane and identifiable).
Port the cut-qa overlap assertion as a cheap post-place check: no two clips on the
dialogue lane may overlap.

### 2. `nativeAudio: .duck` is a fixed volume, and music beds don't duck under dialogue

`ShotPromptBuilder.placedClipVolume` maps duck → 0.3 statically. The harness auto-ducks
the bed only under VO windows (from the clips table). The app places music/ambient beds
at full volume with no keyframes. **Fix:** when placing a music/ambient bed via
`produce_audio`, add volume keyframes (the app has `setKeyframes`) ducking the bed under
every dialogue clip's span (window = clip ± 0.3s, duck to ~0.25). This closes the plan's
own "duck flag unapplied" deferred item.

### 3. Multi-shot prompt cap is a hard prefix cut (loses the geometry hold + trailing beats)

`MultiShotPlanner.multiShotPrompt()` comment says "Trim the longest beat bases first
rather than hard-cutting the tail" but the code does `String(prompt.prefix(limit))` —
exactly the hard tail cut the comment forbids. The geometry-hold clause and the last
beats are the first things deleted. **Fix:** implement the described trimming: shorten
the longest per-beat `base` strings iteratively until the joined prompt fits, keeping
identity declarations, `Lens switch.` separators, blocking lines, and the final
geometry-hold clause intact. Unit-test with an over-limit 6-beat window
(`MultiShotPlannerTests`).

### 4. `wait_for_media` "Asset to wait for not found" race (from HANDOFF-agent-413)

`storyboard_shots` returns placeholder ids the asset registry hasn't registered yet;
`wait_for_media`'s not-found check fires before its wait loop starts. **Fix:** tolerate
unknown ids for a grace period (e.g. 10s) before failing — the tool already has
`timeoutSeconds`; move the existence check inside the polling loop. (The 413 handoff
also remains open — see HANDOFF-agent-413.md, recommended combo B+A+E+C.)

---

## P1 — harness capabilities the app's agentic path lacks

### 4.5 `@ImageN` slot binding — the single biggest consistency delta (harness rule 42)

The app pushes the same tiered `reference_image_urls` stack the harness does, but the
prompt identifies characters by NAME in prose (`MultiShotPlanner.swift` ~121-123 admits
this). The harness derives BOTH the `@ImageN` prompt indices AND the push order from one
slot list, with per-slot role clauses ("@Image1 is Bob", "@Image5 is a second angle of
the same location", "use the plate ONLY for composition") — so the model never guesses
which ref is whom, and the two can never disagree.

**Fix:** build a small `ReferenceSlotPlan` struct in `ProductionOrchestrator` (or a new
`Production/ReferenceSlots.swift`, mirroring `src/mini-drama/reference-slots.ts`): an
ordered list of (asset, role-clause) pairs produced by the existing tier logic. Then:
(a) push `imageRefs` FROM the plan (order guaranteed); (b) when the routed model honors
image tags (manifest set `imageTags` — Seedance R2V family, Grok Imagine R2V; expose it
as `VideoModelCapabilities.usesImageTags(id:)`), prepend the role clauses to the prompt
and substitute character names with their `@ImageN` in shot prompt + blocking + dialogue
lines (the harness prompt builder does the same substitution); (c) on non-tag models keep
the current name-based prose. Applies to BOTH `route()` singles and `routeUnit()` grouped
windows. Gate behind a flag defaulting ON only for the Seedance family (probe-verified),
per the non-regression rule.

### 5. No negative prompts anywhere

`GenerationInput` has no `negativePrompt` field; nothing in the app emits
`negative_prompt`. The harness leans on it for: anti-music/SFX suppression on dialogue
shots (rule 33 appends `background music, soundtrack, score, … sound design, audio drops`
to EVERY shot's negative), anti-realism terms on character refs, film-burn suppression.
The app approximates rule 33 with positive `audioContent` phrasing only.
**Fix:** add `negativePrompt: String?` to `GenerationInput`, thread it through
`VideoGenerationSubmission`/`ImageGenerationSubmission` request bodies (models that
reject it: skip per capability — add a `supportsNegativePrompt` check with conservative
default off, verify against the live API before enabling per family). Then have
`ShotPromptBuilder` emit the rule-33 audio negative for `noMusic`/`ambienceOnly`/
`dialogueOnly` shots, and the character-ref path emit the anti-realism negative when
a stylized (non-photoreal) look is locked.

### 6. Storyboard pass is single-pass; harness is two-pass (generate → multi-edit refine) with location/lighting injection

`storyboard_shots` generates one panel per shot with ≤3 refs and a generic
`"cinematic storyboard frame"` suffix. Harness storyboard: Pass 1 injects the location's
locked description + lightingNotes into the panel prompt and anchors the environment
ref; Pass 2 refines via multi-edit against character refs; consecutive same-location
shots style-match against the previous panel (anti-pattern 7 lighting consistency).
**Fix (incremental):** (a) inject `LocationSpec.description` + spatialAnchors into the
panel prompt (anchors currently reach video prompts but NOT storyboard prompts);
(b) add a `lightingNotes` field to `LocationSpec` and inject it; (c) for consecutive
shots sharing a location, append "match the lighting of the previous panel" and pass
the previous shot's panel as an extra reference. The multi-edit refine pass can stay
manual via `fix_panel` for now, but wire `fix_panel` to pass character refs (it's
currently single-image `/image/edit` — the port plan flagged this).

### 7. `blocking` missing from the storyboard panel prompt

Harness rule 49 injects `BLOCKING: …` into the PANEL prompt so plates carry the
geometry. The app injects blocking into video prompts and the QA rubric but
`storyboard_shots` builds `"\(basePrompt), cinematic storyboard frame, \(motion) motion"`
with no blocking and no anchors. Panels are tier-2 references for video — a panel with
wrong geometry propagates. **Fix:** append `Blocking: …` and
`Fixed layout (never rearrange): …` to the panel prompt, same as
`ShotPromptBuilder.videoPrompt`.

### 7.5 Multi-shot units only anchor the window's FIRST panel; no per-beat blocking plates (harness rule 42 plates)

`routeUnit()` (~499) takes one storyboard panel for the whole window, so beats 2+ have
no composition anchor; the harness gives every beat its own PROTECTED blocking plate.
**Fix (incremental):** include each beat's panel in the unit's slot plan when budget
allows (drop from the bottom tier first, plates last — same overflow policy), with the
"ONLY for composition/blocking" role clause from #4.5. True neutral blocking plates
(composed multi-character location images, no likeness) can come later as an optional
pre-produce step.

### 8. No per-shot recipe/replay record (harness rule 39)

The app records `GenerationInput` per asset (prompt, model, refs, queueId) — good — but
takes don't capture the full replayable call the way `shot-NNN.recipe.json` does
(ordered passes with roles: content/identity/look; refs as stable ids). `ShotTake` only
stores `videoAssetId` + `model`. **Fix (cheap):** snapshot the submitted
`GenerationInput` (with reference asset ids and the final prompt string) onto each
`ShotTake`. That makes "regenerate exactly take 2 but change one word" possible and
gives the user an inspectable prompt history per shot in the Production panel.

### 9. Post-render output validation missing (harness `validate-video-outputs`, anti-pattern 5/10)

R2V models can return portrait when aspect is dropped, and truncated/tiny files read as
success. The app checks nothing after download. **Fix:** after `submitAndAwait`
resolves, assert (a) orientation matches `plan.aspectRatio` (load the video track's
naturalSize), (b) duration ≥ 80% of requested, (c) file size sane. On mismatch treat as
a failed attempt (retry path already exists). This is the app-side equivalent of the
harness's first-frame contact-sheet check.

### 10. Lip-sync shot strategy still deferred (port plan `keyframe-pipeline`)

`audioInputCapable` + `AudioSilencePadder` + `LastFrameExtractor` all exist, but no
orchestrator route uses dialogue MP3 as `audio_url` with a Seedance R2V identity
keyframe (harness rule 32). The voice-reference attachment (rule 40) covers timbre, not
exact lip-sync. Keep deferred if real-world runs are fine, but the router hook is now
cheap: when a shot has `dialogue` with `voiceOver == false`, a character with a locked
voice, and the routed family accepts `audio_url`, TTS the line first and attach it as
`audio_url` instead of the voice-donor sample.

---

## P2 — polish / drift guards

### 11. Storyboard panels aren't validated against plan aspect

Panels generate at `plan.aspectRatio` but multi-edit fixes (`fix_panel`) return square
(anti-pattern 6). The tool description warns about close-ups; add the harness rule:
refuse `fix_panel` on close-up shots (or warn in the result hint) and suggest
regeneration via `storyboard_shots` for that shot instead.

### 12. QA rubric lacks the previous-panel spatial comparison

Harness `qa-storyboard` attaches the nearest prior panel from the same location so
side-swaps are caught against real coverage, and treats spatial flips as FLAG-CRITICAL.
App `qa_shot` reviews one shot in isolation. **Fix:** when the shot has a location and a
prior same-location shot with a ready panel/video, attach that panel's frame to the
`VisionQA.evaluate` image set and extend the rubric: "Compare against the earlier frame
of this location: landmarks must not move or mirror; characters keep screen sides."

### 13. Intelligence-model tier rule (harness rule 46)

`VisionQA.selectModel()` picks the agent model if vision-capable else "first vision
model" — no privacy-tier awareness. If/when the app exposes model privacy tiers in
`ModelCatalog`, prefer a vision model in the SAME tier as the agent model rather than
any first hit.

### 14. Deprecation warnings (harness rule 34)

Harness surfaces `x-venice-model-deprecation-warning` headers as structured warnings.
App ignores them. Cheap add in `VeniceAPI`: log once per (model, date) and
`postSystemNotice` so the agent/user learn before sunset. (PLAN.md 5.6 said "drop
unless proven" for `Deprecation`/`Sunset` headers — the harness has since shipped
reading Venice's OWN header names, which ARE proven; use those.)

### 15. `supportsElements` / `supportsSceneImages` / `perReferenceAudio` stay hard-off

Correct per the sync rule (builders deferred). No action — just re-affirming these are
deliberate, so nobody "fixes" them to read the manifest without building the request
builders + live probes (PLAN.md 5.5).

### 16. QA errors read as "unchecked passed" (harness rule 46b)

`runAutoQA` returns nil on any thrown vision call and the shot proceeds as if fine.
The harness counts errored QA separately and suppresses the "all clear" suggestion.
**Fix:** on QA throw, stamp `qaSummary = "QA errored: <reason> — shot is UNCHECKED"`
and don't count it as a pass in any auto-approve path.

### 17. No seeds recorded or locked

The app never sets a generation seed; the harness locks series seeds for
reproducibility (and records them in recipes). If Venice's video queue accepts a seed
for the routed families, add `seed` to `GenerationInput` + `ShotTake` so a take can be
replayed exactly (pairs with #8). Probe first; skip families that reject it.

---

## Suggested order of attack

1. #1 + #2 (produce_audio scheduler + ducking) — user-audible bugs, one file each.
2. #4 (wait_for_media grace) — unblocks agent runs today (pairs with the 413 handoff).
3. #3 (multi-shot trim) — small, testable, protects paid prompts.
4. #4.5 (@ImageN slot binding) — highest consistency return per line of code.
5. #5 (negative prompts) — unlocks rule 33; needs a capability flag + live probe.
6. #6 + #7 (storyboard location/lighting/blocking injection) — quality of every panel.
7. #8 + #17 (take recipes + seeds) then #9 (output validation) — provenance + drift guard.
8. #7.5, #10–#16 as capacity allows.

## Verification

- Unit: extend `MultiShotPlannerTests` (trim), `ShotPromptBuilderTests` (negatives,
  blocking-in-panel), new `ProduceAudioSchedulerTests` (global cursor, no overlap).
- Live: rerun Jordan's "The Last Espresso" 12-shot run (2 characters, 2 locations,
  Kimi K3) end-to-end: expect zero 413s (other handoff), dialogue in shot order with
  no overlaps, beds ducked, panels carrying blocking, and no portrait/truncated takes
  placed. Full suite must stay green (886+).

## Where everything lives

| Item | Path |
|---|---|
| #1 #2 | `Agent/Tools/ToolExecutor+ProduceAudio.swift`, `Production/ShotPromptBuilder.swift` |
| #3 | `Production/MultiShotPlanner.swift` (`multiShotPrompt`) |
| #4 | `Agent/Tools/ToolExecutor+WaitForMedia.swift` |
| #4.5 #7.5 | `Production/ProductionOrchestrator.swift` (`route`, `routeUnit`), new `Production/ReferenceSlots.swift`, `Production/MultiShotPlanner.swift`; harness `src/mini-drama/reference-slots.ts` + `prompt-builder.ts` |
| #5 | `Models/MediaManifest.swift` (`GenerationInput`), `Generation/` submissions, `Generation/Catalog/VideoModelCapabilities.swift` |
| #6 #7 | `Agent/Tools/ToolExecutor+Storyboard.swift`, `Production/ShotPlan.swift` (`LocationSpec.lightingNotes`), `Agent/Tools/ToolExecutor+VisionQA.swift` (`fixPanel`) |
| #8 | `Production/ShotPlan.swift` (`ShotTake`), `Production/ProductionOrchestrator.swift` (`recordTake`) |
| #9 | `Production/ProductionOrchestrator.swift` (after `submitAndAwait`) |
| #10 | `Production/ProductionOrchestrator.swift` (`route`), `Audio/AudioSilencePadder.swift` |
| #12 | `Agent/Tools/ToolExecutor+VisionQA.swift`, `Production/ProductionOrchestrator.swift` (`qaRubric`) |
| Harness reference | `~/projects/tools/venice-video-harness/AGENTS.md` (rules 21, 32–42, 49; anti-patterns 5–7, 19, 20, 28) |

## Constraints (unchanged house rules)

- Non-regression: anything touching a paid request body goes behind a flag defaulting
  to current behavior; live-probe before enabling (capability-sync rule).
- Harness ↔ app sync rule applies to anything learned while fixing (update BOTH
  `models.ts`/sets and `VideoModelCapabilities`, regenerate + copy `capabilities.json`).
- AppTheme for all UI values; one-line comments; AppKit-parent drop rule; 886-test
  suite green before push.


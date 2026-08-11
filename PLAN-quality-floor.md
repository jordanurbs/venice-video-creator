# Plan: bring Venice Video Creator's production pipeline up to harness quality

Repo: `products/venice-video-editor/` · Reference: `tools/venice-video-harness/`
(AGENTS.md rules 11-12, 37, 42, 46, 50-51). Working record; see the work journal
for progress.

**Problem:** the Creator ported the harness's architecture (reference slots,
blocking, spatial anchors) but not its quality floor. Storyboards render at
minimum resolution/quality with no locked style on an arbitrary model; characters
get 2 cheap reference views, no seed lock, and per-shot renders that drift.

## Phase 0 — Model catalog sync (prerequisite, ~half day)
- 0.1 Add the Seedance 2.5 family to `Venice/SupplementalModels.swift`:
  `seedance-2-5-reference-to-video` (+ t2v if quotable) with the 2.5 spec —
  every integer 4-30s, 480p/720p, aspect 21:9/16:9/4:3/1:1/3:4/9:16, 30 image
  refs, audio_url/reference_audio_urls/reference_video_urls. Delisted from GET
  /models, so a supplemental entry is the only way it appears.
- 0.2 Regenerate `Resources/Capabilities/capabilities.json` from the harness
  registry (`npm run manifest`). The bundled manifest had zero 2.5 entries,
  budgets capped at 9, defaults pointing at seedance-2-0-enhanced. Keep the
  hardcoded 30-ref escape hatch in `VideoModelCapabilities.maxReferenceImages`.
- 0.3 Verify capability-set membership for 2.5 (imageTags, audioInput,
  referenceAudio, maxReferenceImagesByModel[…]=30). Unit test mirroring the
  harness coverage test.
- Verify: 2.5 appears in list_models, routes as R2V with @Image binding.

## Phase 1 — Storyboard quality
- 1.1 Stop generating panels/refs at minimum quality (use the model's default
  or highest ≤1080p-class resolution + default quality) in storyboard, UI
  regenerate paths, and character/location ref creation. Keep cheapestResolution
  for chat-driven generate_image only.
- 1.2 Fix storyboard model resolution: explicit arg → plan.referenceImageModel →
  nano-banana-2/pro → current fallback.
- 1.3 Locked series style block: `ShotPlan.styleBlock`, authored at
  save_shot_plan, injected front-loaded into panel/video/multi-shot prompts and
  as the style component of ref generations; short "Style reminder:" suffix on
  panels (harness rule 11 / anti-pattern 2).
- 1.4 Reorder + raise the panel reference stack: character refs → location ref →
  prior panel; cap = model's maxImageReferences; log dropped refs.
- 1.5 cfg_scale 10 on panels + character refs (harness rule 12) — investigate
  API support first.

## Phase 2 — Character consistency foundations
- 2.1 4-view reference sheets by default (create_character count 2→4).
- 2.2 Set the plan seed at save_shot_plan; thread into GenerationInput for every
  reference, panel, video generation on seed-capable models.
- 2.3 Reference sheets on the locked model at full quality (+ styleBlock).
- 2.4 Restate invariant traits per shot (harness rule 37).

## Phase 3 — Video lane: Seedance 2.5 + longer single-pass windows
- 3.1 Default routing to 2.5 (enable it out of the box; keep 2.0 Enhanced for 1080p).
- 3.2 Update AgentInstructions model-selection text + 15s→30s cap language.
- 3.3 Raise the multi-shot window on 2.5 (30s when routed unit is 2.5, 15s else).
- 3.4 Flip multi-shot grouping default ON (keep per-shot opt-out + Settings toggle).
- 3.5 (Stretch) Timestamped montage grammar — parked behind its own flag.

## Phase 4 — Enforce the QA loop
- 4.1 Auto-QA panels inside storyboard flow / produce_shots gate.
- 4.2 Count errored QA separately (harness rule 46).
- 4.3 Spatial-continuity dimension in qa_shot (prior same-location panel).

## Phase 5 — Docs + guardrails
- 5.1 Update AgentInstructions production-pipeline section.
- 5.2 CONTRIBUTING.md non-regression note (paid bodies changed).
- 5.3 Sync the venice-video-editor ↔ harness drift checklist (harness rule 51).

The riskiest item is 3.4 (grouping default flip) — it changes paid request
bodies; ship behind one release with the changelog note, keep the toggle.

# Harness Enhancements Plan

> **Revision note.** This version is annotated against the actual code in
> `venice-video-editor`, `venice-video-harness`, and `venice-video-mcp` (audit
> 2026-07-02). Each item now carries a **Status** line (what already exists),
> **Corrections** where the original claims were wrong, and a
> **Non-regression** note. Read [Cross-Cutting Prerequisites](#cross-cutting-prerequisites)
> and [Non-Regression Guarantee](#non-regression-guarantee) before starting any item —
> they gate roughly half the work.

## Scope

Use the harness as a source of production guardrails, not as a product rewrite. Palmier Pro stays timeline-first; this plan ports the easiest, highest-value intelligence into the existing generation, model catalog, and assistant-panel surfaces.

Out of scope for this plan:

- Do not add the full series/episode/storyboard workflow from the harness.
- Do not implement the `venice-video-mcp` bridge yet, but keep the assistant-panel architecture compatible with adding it later.
- Do not add the old Seedance provenance/face-image gate. Seedance now only needs the consent parameter, which Palmier Pro already attaches in `Sources/PalmierPro/Venice/VeniceGeneration.swift` (verified: lines 152–162, gated on `ModelPreferences.shared.seedanceConsentGranted`, default `true`).

## Cross-Cutting Prerequisites

These three facts constrain multiple items. Decide them once, up front.

1. **Model-ID mapping.** The harness hardcodes slugs (`seedream-v5-lite`,
   `wan-2-7-reference-to-video`, `kling-o3-standard-reference-to-video`).
   Palmier Pro builds its catalog **live** from `VeniceAPI.fetchCatalog()` via
   `VeniceModelMapper`. Any ported per-model rule (items 2, 6, 7, 8) must key off
   a mapping table or a catalog capability flag, or it silently no-ops when live
   IDs differ. Prefer capability flags over slug matching wherever possible.

2. **The catalog mapper zeroes capabilities.** `VeniceModelMapper.videoEntry`
   (`Sources/PalmierPro/Venice/VeniceModel.swift`, lines 128–145) hardcodes
   `maxReferenceVideos: 0`, `maxReferenceAudios: 0`, `supportsLastFrame: false`.
   Because `runVideo` gates `audio_url` on `maxReferenceAudios > 0`
   (`VeniceGeneration.swift` line 148), **Wan audio (item 6) cannot fire today**,
   and structured refs (item 7) / routing (item 8) have no capability data to read.
   Fixing `videoEntry` is an **unlisted prerequisite** for items 6, 7, 8.

3. **No ffmpeg.** The harness shells out to `ffmpeg` (`apad`, `scale`, `crop`).
   Palmier Pro is a Developer ID AVFoundation/AppKit app and must not gain an
   ffmpeg dependency. Items 6 (audio padding) and 10 (aspect-ratio crop) require
   native `AVFoundation` / `CoreImage` reimplementations, not a copy of the
   harness shell calls.

## Suggested Implementation Order (revised)

Reordered by value-to-effort and dependency, replacing the original 1→11 sequence:

1. Agent instruction updates (item 1).
2. Silent-rejection detection (item 3) — best safety-per-effort.
3. Image-edit aspect-ratio recovery (item 10) — self-contained, native.
4. Prompt length caps (item 2) — after the model-ID mapping decision.
5. **Catalog mapper capability fix** (prerequisite #2) — unblocks 6/7/8.
6. Duration preflight error-message polish (item 5) — mostly already done.
7. Wan audio preflight and padding (item 6).
8. Structured `elements` / `scene_image_urls` support (item 7).
9. Smart model routing (item 8) — as instructions first, code layer later.
10. Continuity / frame-chaining tool (item 9).
11. Future assistant-panel MCP bridge exploration (item 11).

Item 4 (deprecation) is intentionally last-tier; see its note.

---

## 1. Agent Knowledge Updates

Update `Sources/PalmierPro/Agent/Tools/AgentInstructions.swift` with harness rules that need no new UI.

**Status.** `serverInstructions` already covers a lot: prompt word-count formulas
(lines 157–167), "state dialogue/VO/SFX/music explicitly … silent video is
usually a bug" (lines 163–164), character/reference reuse (lines 116–120), and
Seedance/Kling fallbacks (lines 106–110). It does **not** mention Wan, lip-sync,
music/SFX suppression, per-shot duration heuristics, or a troubleshooting playbook.

**Corrections to the original bullets:**

- **Music/SFX suppression must be conditional, not blanket.** The current
  instructions tell the agent to *include* audio and treat silence as a bug.
  A flat "suppress music/SFX" rule contradicts that and will cause whiplash.
  Phrase it as: *"When the user plans to add music or SFX in post, instruct the
  model to keep generated audio to dialogue only (or none)."*
- **Wan/lip-sync routing is conditional on catalog availability.** Palmier's
  current defaults are Seedance/Kling/Grok/Veo — no Wan. **Verify Wan lip-sync
  models actually appear in the live catalog before adding routing rules**, or the
  guidance points at models the app can't select.

Rules to add (revised):

- Prefer longer 15s shots **when the selected model's `durations` include 15**, especially for multi-clip narrative sequences. (Not universal — Wan 2.7 R2V caps at 10s.)
- Ask about dialogue strategy when planning a generation-heavy scene: native model audio, lip-sync, or narrator voice-over.
- When post-production audio will be added separately, tell the model to suppress generated music/SFX (dialogue-only or silent).
- Route visible-face low/medium-motion dialogue toward Wan lip-sync-capable models **if such a model exists in the catalog**.
- Prefer models with structured character/reference support for crowded scenes or recurring characters.
- Add concise troubleshooting hints for common Venice gotchas: wrong aspect ratio, short Wan audio, multi-edit square output, model deprecation warnings, and silent rejects.

**Drafted instruction block** (append after the existing "Prompt craft" section,
matching the terse house voice):

```
# Model selection heuristics
- Shot length: prefer 15s when the chosen model's durations include it; long
  narrative beats read better uncut. Check list_models — some models only allow
  5s/10s and will reject 15s.
- Dialogue: before a generation-heavy scene, ask how speech should be produced —
  native model audio, lip-sync, or a separate narrator VO track.
- Characters: one or two recurring faces, prefer a reference-to-video model with
  reference images. Three or more, prefer a model with structured reference
  support. Atmosphere-only shots, prefer the prompt-first model.
- Post audio: if the user will add music or SFX later, tell the model to keep
  generated audio to dialogue only, or none.

# Venice gotchas
- Aspect ratio: reference-to-video without an explicit aspect ratio can default
  to vertical. State the aspect ratio.
- Multi-edit returns a square image; tight close-ups can lose forehead/chin when
  restored to wide or tall. Avoid multi-edit for detail-critical crops.
- If a generation returns unusually fast with a tiny file, treat it as a failure,
  not a success — retry or change models.
```

Harness references:

- `/Users/venetian42069/Projects/venice-video-mcp/skills/venice-mcp-pipeline/SKILL.md`
- `/Users/venetian42069/Projects/venice-video-mcp/skills/venice-mcp-troubleshooting/SKILL.md`

**Non-regression.** Instructions are additive prose. No code path changes. Worst
case is a suboptimal suggestion, never a broken build or failed generation.

## 2. Prompt Length Guardrails

Add positive-prompt length limits for image models, using harness defaults.

**Status.** Verified against `venice-video-harness/src/venice/models.ts` — the four
numbers below match exactly (`MAX_POSITIVE_PROMPT_CHARS` + `DEFAULT_MAX_POSITIVE_PROMPT_CHARS = 300`).
Palmier has **no** image/video prompt-length validation today; only audio has
`AudioCaps.minPromptLength`. So this is net-new.

- Seedream edit/generate: 300 chars.
- Nano Banana edit/generate: 500 chars.
- GPT Image edit/generate: 600 chars.
- Conservative fallback: 300 chars when a model-specific cap is unknown.

Implementation targets:

- Extend catalog/model metadata near `Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift` or a small helper beside it. Key off the model-ID mapping from prerequisite #1; the 300-char fallback covers unknown IDs safely.
- **Warn, do not hard-block or silently truncate.** Enforce from image submission paths before queueing paid work, but surface a warning the user can override. Silent truncation would change output for existing long prompts.
- Reflect the rule in assistant instructions so generated prompts stay concise.

Harness reference:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/venice/models.ts` (lines 49–79)

**Non-regression.** Safe **only if** implemented as a warning/soft cap. A hard
truncation or block would break currently-working long prompts. Default behavior
for prompts already under the cap is unchanged.

## 3. Silent-Rejection Detection

Port the harness byte-size checks so Palmier Pro detects "HTTP 200 but unusable placeholder media" before saving assets as successful generations.

**Status.** Verified against `venice-video-harness/src/venice/rejection.ts` —
`SILENT_REJECT_THRESHOLD_IMAGE = 30_000`, `SILENT_REJECT_THRESHOLD_VIDEO = 100_000`,
plus a resolution-aware map (512→20KB, 720p→30KB, 1K→50KB, 1080p→75KB, 2K→150KB, 4K→400KB).
Palmier already decodes image base64 (`runImage`, lines 105–110) and MP4 bytes
(`pollVideo`, lines 190–197) before `writeTemp`, so the guard slots in with no
restructuring. **Highest safety-per-effort item.**

Implementation targets:

- Add a small Swift helper near `Sources/PalmierPro/Venice/VeniceGeneration.swift`.
- Check decoded image bytes before `writeTemp(data:ext:)` for image generation/edit/multi-edit/background-remove where applicable.
- Check MP4 bytes before saving retrieved videos.
- Surface a clear generation failure message, not a successful empty asset.

Initial thresholds from the harness:

- Image fallback: 30 KB.
- Video fallback: 100 KB.
- Resolution-aware image thresholds can follow after the simple guard is working.

**Do not** copy the harness's own gap: its mini-drama episode path
(`video-generator.ts` ~L587) writes MP4 bytes **without** calling the video guard.
Wire Palmier's guard into the single shared `pollVideo` path so every video is covered.

Harness reference:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/venice/rejection.ts`

**Non-regression.** Risk is **false positives** — a legitimately small asset
flagged as junk. Mitigate by starting with the conservative flat thresholds
(30 KB / 100 KB), which are far below any real generated frame or clip, and by
converting a "successful empty asset" into an explicit, retryable failure rather
than a hard crash. This strictly improves on today's behavior of saving the stub.

## 4. Deprecation Warning Surfacing

Teach the shared request/response path (`VeniceAPI`, in `Sources/PalmierPro/Venice/`) to capture Venice model deprecation headers.

**Status / correction.** `VeniceAPI.assertOK` checks HTTP **status only** — no
header inspection, so this is feasible. **But the plan assumes Venice emits
`Deprecation`/`Sunset` headers, which is unverified.** Confirm the headers exist
on a real response before building anything; otherwise this is log-only noise.
Lowest-value item — keep it last.

Implementation approach:

- **First, verify** Venice actually returns deprecation headers (inspect a live response).
- Inspect response headers in the shared request/response path.
- Record deprecation warnings in a lightweight app-visible channel: logs first, then generation failure/warning UI if an existing status surface supports it cleanly.
- Include deprecation information in assistant-visible model listing if practical.

This is a cheap operational improvement: users can avoid building scenes around models that are about to disappear.

**Non-regression.** Read-only header inspection plus logging. No effect on request
building or existing generations.

## 5. Stronger Duration Preflight

Use harness duration validation as a fail-fast layer before any paid video queue request.

**Status / correction — mostly already done.** `VideoModelConfig.validate()`
(`Sources/PalmierPro/Generation/Catalog/VideoModelConfig.swift`, lines 51–81)
already validates durations, and **both** the UI (`GenerationView.preflightValidation`)
and the agent (`ToolExecutor+Generate`) already funnel through it via
`VideoGenerationSubmission`. The plan's sub-goal "ensure both hit the same
validation path" is **already satisfied**. The only real increment left is
clearer stepped-ladder error text. Downgraded to polish.

Remaining work:

- Add clearer error messages for stepped duration ladders such as 5s/10s-only R2V models (verified real: Wan 2.7 R2V is 5s/10s in the harness registry).
- Prefer failing before placeholder creation when model constraints are invalid.

Harness reference:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/mini-drama/video-generator.ts` (`assertShotDurationsValid`, lines 1144–1223)

**Non-regression.** Message-only changes over an existing validation path. No new
rejections beyond what `validate()` already produces.

## 6. Wan Audio Preflight And Padding

Port the Wan 2.7 audio minimum-duration guard.

**Status.** Verified against `venice-video-harness/src/venice/audio-preflight.ts`:
Wan 2.7 minimum is **3s**, padded with **trailing** silence (`apad`). **Blocked by
prerequisite #2**: today `audio_url` is only attached when `maxReferenceAudios > 0`
(`VeniceGeneration.swift` line 148), and the mapper hardcodes it to `0`, so Wan
audio never fires. Fix the mapper first.

Implementation approach:

- Add a model capability field for minimum audio input seconds, starting with Wan 2.7 at 3s.
- Before submitting `audio_url`, probe local audio duration with `AVFoundation` where Palmier has a local file path.
- If shorter than the minimum, create a padded copy with trailing silence using an **`AVFoundation` silence-append export** (not ffmpeg) and use that for the request.
- If the audio is remote or cannot be probed, show a clear warning or let the request proceed with a better error path.

Implementation targets:

- Fix `VeniceModelMapper.videoEntry` to stop zeroing `maxReferenceAudios` for audio-capable models.
- Model metadata in `ModelCatalog.swift` / `VideoModelConfig.swift`.
- Submission preprocessing before `VeniceGeneration.swift` builds the request body.

Harness reference:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/venice/audio-preflight.ts`

**Non-regression.** Padding only triggers below the minimum; audio already ≥ 3s is
untouched. The padded copy is a new temp file — the user's source audio is never
mutated. **Caveat:** enabling `maxReferenceAudios` in the mapper is itself a
behavior change (audio refs start being sent). Gate it to models that genuinely
support audio so no currently-working request gains an unexpected parameter.

## 7. Structured Video References: `elements` And Scene Images

Add support for harness-style structured references where Venice models support them.

**Status / correction.** These fields (`elements`, `scene_image_urls`) do **not**
exist in Palmier's request code. The live catalog can't say which models support
them, so this would require hardcoded slug allowlists — the exact brittleness this
port is meant to avoid. **The harness is itself internally inconsistent here:** its
registry marks `wan-2-7-reference-to-video` as `supportsElements: true`, but its
runtime `MODELS_SUPPORTING_ELEMENTS` set excludes it and routes it through flat
`reference_image_urls`. Do not port the contradiction. **Highest effort / risk —
keep it late and gate strictly.**

Implementation targets:

- Extend `VideoCaps` in `ModelCatalog.swift` with `supportsElements`, `supportsSceneImages`, `perReferenceAudio` — populated from an explicit, small allowlist, not guessed from the catalog.
- Extend `VideoModelConfig.swift` and `VideoGenerationParams` to represent structured references.
- Update `VeniceGeneration.swift` to emit `elements` and `scene_image_urls` **only** for explicitly-listed supporting models.
- Keep flat `reference_image_urls` as the fallback path (this is what almost every model uses).

Harness references:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/venice/models.ts`
- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/mini-drama/video-generator.ts` (lines 487–543)
- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/series/types.ts` (capability sets, lines 633–717)

**Non-regression.** Safe **only if** the new params are emitted behind a positive
capability flag defaulting to off. The existing flat-`reference_image_urls` path
must remain the default and stay untouched for every model not on the allowlist.

## 8. Smart Model Routing Helper

Create a routing layer that assistant tools and UI flows can share.

**Status / correction.** Verified against `prompt-builder.ts` / `generation-planner.ts`.
The real rules use specific slugs and need capability data the catalog doesn't
expose yet (prerequisite #2). One factual fix: **multi-shot bundling uses
`kling-o3-pro-image-to-video`, not Seedance** (`generation-planner.ts` `KLING_MULTISHOT_MODEL`).
**Start as agent instructions (folded into item 1), not a code layer** — the code
layer is blocked on items 6/7's capability work.

Rules to start with (as instructions):

- Establishing or atmosphere-only shot: use the preferred atmosphere/prompt-first model.
- One or two recurring characters: prefer reference-to-video with reference images.
- Three or more characters: prefer a model with structured reference support.
- Visible-face dialogue with low or medium motion: prefer the lip-sync path when the user wants consistent spoken delivery (only if such a model exists in the catalog).
- High-motion dialogue: prefer R2V over lip-sync to preserve action and identity.

Implementation targets:

- Phase 1: encode the rules in `AgentInstructions.swift` (see item 1's drafted block).
- Phase 2 (later): a helper near `Sources/PalmierPro/Generation/Catalog/` once the catalog exposes the capabilities it needs.

Harness references:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/mini-drama/prompt-builder.ts` (`resolveVideoModel`, lines 163–225)
- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/mini-drama/generation-planner.ts`

**Non-regression.** Phase 1 is instruction-only (see item 1). Phase 2 must ship as
a *suggested default* the user can override, never a forced override of an
explicit model choice.

## 9. Continuity And Frame-Chaining Workflow

Upgrade Palmier Pro's existing last-frame tooling into a more opinionated continuity helper.

**Status / correction.** `LastFrameExtractor.pngData` exists but is **UI-only** —
called from `EditorViewModel+AIEdit.createVideoFromLastFrame`, wired to the AI Edit
menu. The agent has **no** tool to extract a clip's last frame. So "assistant
workflow over existing tools" is **not possible today** — the agent would need a
small extraction tool (or a `generate_video` param that seeds from a clip's last
frame) before any continuity guidance is actionable.

Implementation targets:

- Build on `Sources/PalmierPro/Generation/Edit/LastFrameExtractor.swift`.
- **Add a thin agent tool** (or extend `generate_video`) that extracts the last frame of an existing clip so the agent can chain shots — `startFrameMediaRef`/`endFrameMediaRef` already exist but nothing produces the frame for the agent.
- Add assistant guidance for when to use previous last frame, approved panel/still, or next-panel end frame.

Harness reference:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/mini-drama/generation-planner.ts` (continuity rules, lines 127–169)

**Non-regression.** New tool + new instructions are purely additive. The existing
UI last-frame flow is untouched.

## 10. Image Edit Aspect-Ratio Recovery

Bring over the harness lesson that Venice multi-edit returns square images and can crop important detail when restored to wide/tall formats.

**Status.** Verified: `runImageMultiEdit` (`VeniceGeneration.swift`, lines 46–58)
sends **no** `aspect_ratio` and Venice returns 1024². The harness recovery
(`panel-fixer.ts` `restoreAspectRatio`, lines 74–114) center-crops then scales.

Implementation targets:

- Review image edit and multi-edit handling in `VeniceGeneration.swift`.
- Add aspect-ratio restoration for AI Edit outputs using **`CoreImage`/`AppKit`** (not ffmpeg): center-crop the square to the source aspect ratio, then scale to source dimensions.
- Warn or avoid multi-edit for tight close-ups when forehead/chin/detail preservation matters (fold the warning into item 1's Venice gotchas block).

Harness references:

- `/Users/venetian42069/Projects/video-proj/venice-video-harness/src/mini-drama/panel-fixer.ts`
- `/Users/venetian42069/Projects/venice-video-mcp/skills/venice-mcp-troubleshooting/SKILL.md` (A5)

**Non-regression.** Only affects multi-edit output, which is currently square
regardless. Restoring the source aspect ratio is a strict improvement for the
common case. To be fully safe, make restoration the behavior only when a target
aspect ratio is known, and skip when source and square are within tolerance
(as the harness does at 0.01) so square-input edits are untouched.

## 11. Future Assistant-Panel MCP Bridge

Do not build this now. Keep it as a later integration once the smaller guardrails prove useful.

Possible future shape:

- Add an optional assistant-panel action that can talk to `venice-video-mcp` as a sidecar.
- Use the MCP for coarse production workflows only: series setup, character references, episode generation, batch video creation, and assembly.
- Import completed MP4/still/audio outputs back into Palmier Pro through existing media import and timeline placement tools.
- Keep Palmier's own MCP server focused on timeline-native editing.

Reference:

- `/Users/venetian42069/Projects/venice-video-mcp/src/server.ts`

**Non-regression.** Deferred; no code impact.

---

## Non-Regression Guarantee

The plan can be delivered as **purely additive** — enhancing, never harming — if
every item follows these rules. This is a design constraint, not an automatic
property; naive implementations of items 2, 3, 6, 7, and 8 *could* regress
behavior, so each is gated below.

| Item | Regression risk | Guardrail that keeps it additive |
|---|---|---|
| 1 Instructions | None | Prose only; no code path changes. |
| 2 Prompt caps | Truncating/blocking valid long prompts | **Warn, never truncate/block.** Prompts under cap unchanged. |
| 3 Silent-reject | False-positive on a small valid asset | Conservative flat thresholds; convert stub-save into retryable failure. |
| 4 Deprecation | None | Read-only header inspection + logging. |
| 5 Duration | None | Message-only over existing shared `validate()`. |
| 6 Wan audio | Padding wrong audio; sending new `audio_url` | Pad only below-minimum to a new temp file; gate `maxReferenceAudios` to truly audio-capable models. |
| 7 Elements | Emitting unsupported params to a model | Emit only behind a positive allowlist flag defaulting off; flat refs stay default. |
| 8 Routing | Overriding an explicit user model choice | Suggest defaults only; never override explicit selection. |
| 9 Continuity | None | New tool + instructions; UI flow untouched. |
| 10 Aspect | Changing square output users might expect | Restore only when target AR known; skip within tolerance. |
| 11 MCP | None | Deferred. |

Enforced global invariants:

- **No existing request parameter is removed or changed by default.** New params
  are opt-in behind capability flags that default to the current behavior.
- **New rejections replace silent bad saves, not valid successes.** Thresholds
  start conservative and can tighten later.
- **Guardrails warn before they block.** Anything that could stop a
  currently-successful paid generation surfaces as an overridable warning first.
- **Source media is never mutated.** Padding and aspect recovery write new temp
  files.
- **The shared UI/agent validation path stays shared** — no divergent second path
  that could drift.

# New-session handoff: implement concept-to-export audit fixes

Paste the following prompt into a new session rooted at `/Users/venetian42069/projects/products/venice-video-editor`.

---

Implement the saved concept-to-export remediation plan for Venice Video Creator. Do not repeat the whole audit or stop at another proposal. Work in reviewable phases, add regression tests, and keep the saved plan's progress and validation results current. Do not claim E2E readiness until the specified gates actually pass.

## Read first

1. `AGENTS.md`.
2. `PLAN-concept-to-export-2026-09-17.md` — execution checklist and exit gates.
3. `AUDIT-concept-to-export-2026-09-17.md` — F01–F11 evidence, contract details, and full acceptance scenarios.
4. Current `git status` and diff, then the relevant implementation and tests. Older `HANDOFF.md`, `PLAN.md`, and parity/quality plans can be stale; verify against code rather than following them blindly.

## Product objective

A reliable real in-app agent workflow: concept/idea → saved shot plan → automated character/location references with manual choices and tweaks → automated storyboards with manual corrections and approval → generated video → automated audio generation and agent/manual editing → verified export. Include MiniMax H3 Max, Max Turbo, and Max Multi-Angle, with six start/end camera settings.

## Current state and safety

- The previous session audited and wrote documentation only; it did not implement the fixes. No paid requests, fresh live catalog probes, native UI execution, or export acceptance occurred.
- Both app and local harness have substantial pre-existing uncommitted work. Preserve it. The app already has partial Max/Turbo support and an untracked harness importer plus tests; these are not disposable files.
- Harness: `/Users/venetian42069/projects/tools/venice-video-harness`. At audit time HEAD was `1a0be74` and Multi-Angle changes were uncommitted. Local files do not prove a published release. Do not edit the sibling repo without appropriate filesystem permission.
- A prior `swift build` stopped before app compilation because sandbox access to `/Users/venetian42069/.cache/clang/ModuleCache` was denied. Escalated approval was rejected because the automatic approval reviewer failed. Log: `/tmp/venice-audit-build.log`. Build and tests are unverified, not failed product tests. Obtain explicit permission or an authorized environment before retrying; do not evade the rejection with indirect execution or alternative cache paths. Safe source/document work can continue meanwhile.
- Use `AppTheme` constants for all UI styling. Parent drop targets containing other targets must be native AppKit. Minimal comments; calm, terse native-Mac product copy.
- Do not spend API credits without explicit approved budget and stage stop points. Do not enable unrelated deferred capabilities or change the global default model family as a side effect.

## Highest-priority defects

- **F01:** production status inserts Swift planner structs into Foundation JSON, producing `{}` for a nonempty queue; terminal counts conflate success with settled failure.
- **F02:** storyboard references force R2V, bypassing explicit I2V choices; inherited-aspect I2V is rejected by config validation.
- **F03:** grouped beats share an asset but lack durable shot→clip/source-range identity; retakes, resets, and dialogue can target the first beat.
- **F04:** production reorder/mix mutates video only, missing the audible linked audio clips.
- **F05:** final failed/unavailable QA can advance; panel corrections retain stale approval; grouped QA does not review every beat. Add revision-bound panel/take reviews and shared service gates with deliberate human overrides.
- **F06:** pending job bindings are lost and recovered callbacks do not complete audio sizing/reflow. Persist operations before waits and reconcile exactly once.
- **F07:** export returns “started”; the agent cannot query/wait for validated completion or enforce final readiness.
- **F08–F11:** audio reruns/estimated ducking/bed duration and overruns; duplicate/native/exact-speech ownership; image edit model/quality provenance; incomplete attempt costs and permissive output validation.

Use the dated audit for source paths and detailed fixes. Preserve existing request-budgeting, wait grace, reference slots/styles, recipes, audio reflow, ducking, validation, and QA annotation work instead of rewriting it blindly.

## MiniMax essentials

Five lanes are already partially present: Max T2V/I2V/R2V and Turbo T2V/I2V. Add complete plumbing for `minimax-h3-max-multi-angle`, not just a picker entry. Harness references are `src/venice/models.ts`, `src/venice/types.ts`, `tests/camera-trajectory.test.mjs`, and root `capabilities.json` (`supportsCameraTrajectory`). Reconcile manifest/schema policy carefully.

Six UI settings are start/end horizontal angle (`azimuth`), vertical angle (`elevation`), and relative distance (`distance`). Serialize as `camera_trajectory` keyframes with normalized `time` 0 and 1, not six top-level API keys. Preserve imported advanced trajectories.

Validate 2–12 frames, finite numbers, strictly increasing time in [0,1], elevation [-90,90], distance >0, and total absolute consecutive azimuth changes ≤11,520°. Distance 1 means unchanged, not meters.

Recorded harness contract: integer durations 5–15s; Max/Turbo 768P/480P; Multi-Angle 1080P/768P/480P with automatic 768P and explicitly quoted 1080P; I2V omits `aspect_ratio`; no end frame; non-toggleable native audio means omit `audio`; no Turbo R2V; Max R2V supports up to nine image refs and `audio_url`; simple prompts; Multi-Angle may omit its prompt. Confirm live availability before paid probes. Do not silently substitute another model/lane.

## Execution order

1. Authorized baseline and deterministic provider/catalog/QA/clock/export seams; failing regressions.
2. Correct model routing and complete MiniMax through persistence, UI, agent, and final request fixtures.
3. Production status, durable shot/line/job identity, linked-group mutations, and recovery.
4. Revisioned review/approval, image fidelity/provenance, stricter output validation and attempt/budget ledger.
5. Idempotent measured audio finishing, speech ownership, and verified audio-input exact-speech lane.
6. Shared readiness checks, retained export jobs, agent status/wait, immutable snapshot, and decoded artifact validation.
7. Deterministic integration → native manual-tweak/UI acceptance → approved-budget live model probes and real-agent E2E.

First implementation slice: inspect current diffs and shared types, establish the permitted baseline/test path, add the F01 queued-status regression and minimal correction, then work on F02 and the shared camera trajectory contract. Continue through the plan as session capacity allows; leave an exact next-step handoff if unfinished.

## Acceptance and reporting

Use a 35–50s fixture with two characters, two locations, six shots, shared-asset beats, a separate Multi-Angle shot, VO/dialogue/music/ambient, reversed generation completion, and long TTS. Include manual canonical-reference/panel changes, partial retakes, agent and manual audio/timeline edits, undo/reopen, H.264 master, and portable project export.

A deterministic tool test is not evidence that manual UI tweaks or the live agent work. No UI automation target existed at audit time. Add coverage or record reproducible manual evidence. No live test without approved spend. Exact-speech/lip-sync remains outstanding until its actual audio-input lane is verified.

At each stopping point report implemented fixes, files changed, commands/tests and actual results, unresolved risks, and the next slice. Update the saved plan, distinguish implemented from verified, and do not mark the overall workflow complete based on “export started” or file existence alone.

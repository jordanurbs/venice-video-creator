# HANDOFF: Agent HTTP 413 — oversized chat payloads still occurring

**Date:** 2026-08-06 · **State:** live bug, partial fix shipped in `52d3e00`, still reproducing
**Repro:** Jordan's "The Last Espresso" production run (12 shots, 2 characters, 2 locations,
model **Kimi K3**), screenshot shows the 413 error banner appearing mid-run right after
`storyboard_shots` → `wait_for_media` → `get_media`.

## Symptom

`The request was too large for Venice (HTTP 413)` in the agent panel. Venice rejects the
`chat/completions` request body at the HTTP layer before the model sees it. Once a session
gets heavy enough, every subsequent turn fails the same way (the payload only grows).

## What `52d3e00` already did (and why it wasn't enough)

1. `ContextBudget.fit` now strips inline images from the RECENT window (not just older turns)
   when over budget.
2. `fitToContextBudget` gained a payload ceiling: `min(tokenWindow, maxPayloadBytes/4 = 750k tokens)`.
3. Honest 413 error copy.

It didn't work because of the four root causes below — verify each against the code before
designing the fix.

## Root causes (confirmed in code, in order of impact)

### RC1 — `stripImages` misses images nested inside `tool_result` blocks

`ContextBudget.stripImages` (ContextBudget.swift ~line 64) only matches TOP-LEVEL
`{"type": "image"}` blocks. But in a production run, most images arrive as
**`tool_result` content**: `inspect_media`, `qa_shot` / VisionQA frames,
`ToolExecutor+Timeline` frame grabs, `ToolExecutor+Color` scopes — all append
`.image(base64:)` blocks INSIDE the tool_result's `content` array
(`contentBlockJSON` in AgentService.swift ~line 751 nests them).

Meanwhile `blockChars` DOES recurse into `tool_result` content when **counting**. Net
effect: the budgeter sees the tokens, tries to strip, removes nothing (top-level only),
the `while` loop hits the `keepRecent` floor / orphan-tool-result guards, and the
**still-over-budget message list is returned and shipped anyway** — `fit` has no
post-condition check and no failure signal.

### RC2 — mention images are re-inlined into EVERY historical user message on EVERY request

`apiMessages()` (AgentService.swift ~line 596) loops over ALL stored messages and, for
every past user message with image mentions, calls `inlineImageBlocks(...)` again —
fresh base64 of up to ~1.2MB per image (ImageEncoder.maxBytes), per mention, per turn.
A session where the user @-mentioned a few reference images early keeps paying that cost
on every subsequent request forever. Base64 also inflates bytes 4:3 and the token
estimate (chars/4) underestimates the true request-body byte cost of image data
relative to what the server's byte cap sees.

### RC3 — token estimation vs byte reality

The whole budget pipeline thinks in estimated tokens (`chars/4`). Venice's 413 is a raw
**request-body byte cap**. The `maxPayloadBytes` ceiling I added is applied by converting
bytes→pseudo-tokens and min-ing with the context window, which inherits RC1's blindness:
if stripping can't actually remove the weight, the ceiling is aspirational. Nothing ever
measures the ACTUAL serialized `JSONSerialization.data(...)` byte size before send
(VeniceAgentClient.run has it in hand at ~line 51 and could enforce a hard gate).

### RC4 — Kimi K3's large context window means the token budget never trips first

`availableContextTokens` for Kimi K3 is large, so `budget` is dominated by the payload
ceiling (750k pseudo-tokens ≈ 3MB) — which is the right idea, but combined with RC1/RC2
the fit pass can't reduce below it, and there's no fallback.

## Solution directions to explore (not prescriptive — evaluate trade-offs)

**A. Make stripping recursive (smallest correct fix).** Teach `stripImages` to walk into
`tool_result` content arrays and replace nested image blocks with the placeholder. Also
consider replacing rather than keeping the ENTIRE base64 in stored history: strip at
STORAGE time for tool results older than the current turn (the model has already seen
them once; the assets remain addressable by id via `inspect_media`).

**B. Stop re-inlining historical mention images (RC2).** Only inline mention images for
the NEWEST user message; older user messages keep just the text hint (the note already
says "attached inline — do not call inspect_media", which becomes wrong; adjust the hint
when not inlined). This alone probably removes most of the steady-state payload.

**C. Hard byte gate at the client.** In `VeniceAgentClient.run`, measure
`body.count` after serialization; if over a cap (empirically find Venice's — the 413
threshold isn't documented; binary-search with test payloads or read the error body),
loop back with a progressively more aggressive strip (or throw a typed
`payloadTooLarge` the AgentService catches to re-fit and retry ONCE with images fully
stripped). This is the only layer that measures the real number the server judges.

**D. Ephemeral image turns.** Treat inline images as single-use: after the assistant's
next reply lands, rewrite the stored message to replace image blocks with
`[image <assetId> shown earlier — use inspect_media to re-view]`. Keeps sessions light
permanently, at the cost of the model not being able to "look back" without a tool call.

**E. Reduce at the source.** `ImageEncoder.maxBytes` is 1.2MB; agent-context images
don't need that. A dedicated `agentContext` encoding profile (e.g. ≤768px long edge,
q0.6, ~150–300KB) would cut payloads ~5-8x with no architectural change. Same for
VisionQA/inspect frame grabs (`maxEdge: 768` already, but check actual sizes).

**Recommended combination to start:** B + A + E (removes the recurring weight, makes the
budgeter actually able to strip, shrinks everything at the source), with C as the final
backstop so a 413 becomes structurally impossible rather than merely unlikely.

## Secondary bug seen in the same session (separate, worth its own look)

`wait_for_media` failed with `Asset to wait for not found: BA4600B0` immediately after
`storyboard_shots` returned those ids — the agent called it "registration lag" and worked
around via `get_media`. Suggests `storyboard_shots` returns placeholder ids before
they're registered in `mediaAssets` (or a main-actor ordering issue). Find where
storyboard placeholders are created vs where `wait_for_media` resolves ids; either
register before returning, or make `wait_for_media` tolerate not-yet-registered ids for
a grace period (it has a `timeoutSeconds` arg — the not-found check fires before waiting).

## Where everything lives

| Thing | Path |
|---|---|
| Budgeter (RC1) | `Sources/VeniceVideoCreator/Agent/ContextBudget.swift` (`fit`, `stripImages`, `blockChars`, `maxPayloadBytes`) |
| Request assembly + re-inlining (RC2) | `Sources/VeniceVideoCreator/Agent/AgentService.swift` (`apiMessages`, `inlineImageBlocks`, `fitToContextBudget`, `keepRecentTurns=6`) |
| HTTP client (C) | `Sources/VeniceVideoCreator/Venice/VeniceAgentClient.swift` (`run` — body serialized ~line 51) |
| Error mapping | `Sources/VeniceVideoCreator/Agent/Clients/AgentClientError.swift` (413 branch) |
| Image encoding (E) | `Sources/VeniceVideoCreator/Utilities/ImageEncoder.swift` (`maxBytes = 1_200_000`) |
| Tool-result images | `ToolExecutor+{Timeline,Color,InspectTimeline,VisionQA}.swift` (`.image(base64:)` blocks) |
| Existing tests | `Tests/VeniceVideoCreatorTests/Agent/ContextBudgetTests.swift` (4 tests; add nested-tool_result and byte-gate coverage) |
| wait_for_media bug | search `wait_for_media` in `Agent/Tools/` + `storyboard_shots` placeholder creation in `ToolExecutor+Storyboard.swift` |

## Constraints

- Don't regress the vision gating: non-vision models 400 on ANY image block, so all
  stripping/placeholder paths must keep that branch intact (`modelSupportsVision`).
- Keep `tool_use`/`tool_result` pairing invariants in `fit` (orphan guards exist for a
  reason — Venice rejects orphan tool messages).
- Any change to what gets stored in session history must round-trip through the
  session Codable (AgentMessage) without breaking old saved sessions.
- Test with Kimi K3 specifically (Jordan's driver model) and at least one small-context
  model to confirm the token path still trips first where it should.

## Definition of done

A production run that creates 2+ characters and 2+ locations with generated references,
storyboards 12 shots, and produces them — with image mentions and inspect_media calls
along the way — completes without a single 413, and a synthetic test proves the
serialized request body stays under the byte cap even with 20 image-bearing tool
results in history.

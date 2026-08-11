# Contributing

## How to contribute

The best way to contribute is to open a Github issue. Bug reports, feature requests, ideas are welcome.

With AI coding, human reviews are the bottleneck. We don't have the bandwidth to review large unsolicited PRs.

## Getting Started

### Prerequisites
- macOS 26+
- Xcode 16+
- Swift 6.2 toolchain

### Develop
```bash
git clone https://github.com/jordanurbs/venice-video-creator
cd venice-video-creator

swift build
swift run
```

For a bundled debug build that launches the `.app` and streams OSLog:

```bash
./scripts/dev.sh
```

## Test

```bash
swift test
```

## Non-regression: paid request bodies

Anything that changes what a **paid** Venice request body looks like — resolution,
quality, `seed`, `negative_prompt`, reference-image count/order, or multi-shot
grouping — is held to a non-regression rule: it must be opt-in behind a flag (or a
capability probe) defaulting to current behavior, and a capability the manifest
does not yet carry into a working request builder stays hard-off until the builder
lands and a live `/video/quote` (or `/image/generate`) probe confirms it. See
`.cursor/rules/harness-app-capability-sync.mdc`.

When a change intentionally alters a paid request body, **call it out in the
release notes** (the changelog the release script assembles from commits) so users
know their generations may cost or look different. The 2026-08 quality-floor pass
changed three such defaults deliberately:

- **Storyboard panels and character/location reference sheets** now generate at a
  real resolution (best up to a ~1080p class) instead of the cheapest tier — they
  are the references the video anchors on. Chat-driven `generate_image` still
  defaults to the cheapest resolution.
- **`save_shot_plan` locks a series seed** and threads it into reference/panel/video
  generations *on seed-capable families only* (the emission allowlist is empty
  until a family is probe-verified — plumbing is in place, no seed reaches a paid
  request yet).
- **Multi-shot grouping defaults ON.** Consecutive same-scene shots render as one
  generation (up to 30s on Seedance 2.5) instead of one render per shot. Per-shot
  `allowMultiShot=false` and the Settings → Models toggle are the opt-outs.

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).

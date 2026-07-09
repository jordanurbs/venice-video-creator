# Privacy & Integrity Audit

**Auditor:** Claude Fable 5 (`claude-fable-5`), running as an automated coding agent
**Date:** 2026-07-09
**Commit audited:** `8a73936` (findings 1–6 below were fixed in the follow-up work
that introduced first-run setup opt-ins; finding 7 was mitigated by AI-history
stripping on export and log redaction)
**Scope:** Full repository — all Swift sources, scripts, plists, entitlements, dependency
manifests (`Package.swift` / `Package.resolved`), CI workflows, and the embedded
`.mcpb` Node bundle (including its vendored `node_modules`).

> This audit was performed by an AI agent. It reflects the state of the repository at the
> commit above and should be re-run after significant changes. It is not a substitute for
> independent human review.

---

## Verdict

**No telemetry. No analytics. No tracking identifiers. No crash reporting.**

The only destination user content is ever uploaded to is `api.venice.ai`, using the
user's own API key stored in the macOS Keychain. There is no first-party server, no
analytics SDK, and no device or install identifier anywhere in the codebase.

Every other network-adjacent behavior (update checks, skill catalog, local MCP server,
Seedance consent) ships off and is offered as an explicit opt-in during first-run setup,
adjustable later in Settings. Details below.

## Telemetry: none

- `Sources/VeniceVideoCreator/Telemetry/Telemetry.swift` is a permanent no-op stub.
  `isEnabled` is hardcoded `false`; every method body is empty. The Sentry SDK used by
  the original upstream app has been removed entirely.
- `Package.swift` / `Package.resolved` contain no analytics, telemetry, or
  crash-reporting SDK (checked against Sentry, Crashlytics, Firebase, Amplitude,
  Mixpanel, Segment, PostHog, TelemetryDeck, AppCenter, Bugsnag, Datadog, New Relic,
  Aptabase, Countly, Matomo, Plausible, Google Analytics, Statsig, LaunchDarkly).
- No device/user fingerprinting: no install UUID, no `IOPlatformUUID`, no serial
  number, no MAC address, no persisted identifier in `UserDefaults`.
- Crash logs are written to a local file only
  (`~/Library/Logs/VeniceVideoCreator/crash.log`) and never transmitted.
- The embedded MCP bundle (`Resources/MCPB/venice-video-creator.mcpb`) proxies to
  `http://127.0.0.1:19789` (loopback) only and contains no analytics packages.

## Complete network egress inventory

| Destination | When | What leaves the device | Opt-in? |
|---|---|---|---|
| `api.venice.ai` | User AI actions; model catalog at launch if a key is configured | Prompts, chat history, timeline frame images, reference media, transcription audio, voice samples, parsed documents — sent with the user's own key | Yes — entering a BYO key is the consent gate |
| `raw.githubusercontent.com` (Sparkle appcast) | Only if opted in: launch + hourly on app activation; or a manual Check for Updates | Standard HTTP GET (app version / OS in user agent). Check-only; installs are user-confirmed and EdDSA-verified | Yes — off by default (finding 2, fixed) |
| `raw.githubusercontent.com/palmier-io/palmier-skills` | Only if opted in, when the Skills settings pane is opened | GET only (catalog JSON) | Yes — off by default (finding 6, fixed) |
| `huggingface.co/palmier-io/siglip2-base-coreml` | User clicks download | GET only; SHA-256 pinned | Yes |
| `github.com` releases (update DMG) | User confirms an update install | GET only; signature-verified | Yes |
| Arbitrary HTTPS hosts | Agent/MCP `import_media` tool with a URL; Venice-returned generation `download_url` | GET only (download); HTTPS forced, 5 GB cap | Agent-mediated |
| Browser handoffs (feedback, docs) | User clicks | Feedback issue URL embeds app + macOS version | Yes |

Also verified absent: WKWebView / remote content rendering, CloudKit / iCloud, push
notifications, WebSockets, hardcoded secrets, clipboard polling, camera / microphone /
screen capture, Spotlight scanning. The local MCP server binds strictly to `127.0.0.1`
with Origin validation.

## Opt-in model

Every network-adjacent behavior that is not a direct user AI action ships **off** and
is offered as an explicit opt-in during first-run setup (`Project/SetupOverlay.swift`),
with the same switches available later in Settings:

| Behavior | Default | First-run setup | Settings location |
|---|---|---|---|
| Background update checks (Sparkle appcast) | Off | Yes | General |
| Community skill catalog fetch (GitHub) | Off | Yes | General (and Skills pane) |
| Local MCP server (127.0.0.1:19789) | Off | Yes | Agent |
| Seedance face-media consent | Off | Yes | Models |
| Cloud transcription (Venice STT) | Off | — | Storage / transcription prefs |
| Search model download (Hugging Face) | User-clicked | — | Storage |

Manual "Check for Updates…" remains available regardless — it is user-triggered.

## Findings and resolutions

Original findings from the 2026-07-09 audit, with their current status:

1. **Misleading privacy toggle** (inert "crash reports go to Sentry" toggle in
   `Settings/PrivacyPane.swift`) — **Fixed.** Replaced with real controls for the
   update-check and skill-catalog opt-ins plus an accurate no-telemetry statement.
2. **Automatic update check** (`App/Updater.swift` fetched the appcast at launch and
   hourly regardless of consent) — **Fixed.** Background checks now run only when
   `Updater.isBackgroundCheckEnabled` is on (default off; opt-in at first run or
   Settings → General).
3. **Seedance consent defaulted to granted** — **Fixed.**
   `seedanceConsentGranted` now defaults to `false`; opt-in at first run or
   Settings → Models.
4. **MCP server on by default** — **Fixed.** `MCPService.isEnabledPreference` now
   defaults to `false`; opt-in at first run or Settings → Agent. The server remains
   loopback-only with Origin validation. Note: it is still unauthenticated once
   enabled — any local process can invoke editor tools.
5. **Dead Sentry plumbing in build script** — **Fixed.** The `SentryDSN` Info.plist
   injection and `sentry-cli` dSYM upload were removed from `scripts/bundle.sh`.
6. **Skill catalog auto-fetch** — **Fixed.** `SkillCatalog.refresh()` is a no-op
   unless `SkillCatalog.isEnabledPreference` is on (default off); the Skills pane
   shows an explicit "Enable catalog" affordance instead.
7. **Local data notes** — **Mitigated.**
   - *Sharing AI history:* the "Export → Venice Project" flow (and the agent's
     `export_project` tool) now defaults to **excluding** AI history from shared
     packages — the `chat/` directory, the generation activity log, and per-asset
     provenance (prompts, reference/result URLs, job handles, original import paths)
     are stripped unless "Include AI history" is explicitly enabled.
   - *Log redaction:* unified-log lines no longer contain user media filenames or
     paths. User files are logged as `Log.ref()` (extension + short path hash, for
     correlation without content) and remote URLs as `Log.remote()` (scheme + host
     only, since query strings can carry signed tokens). Prompts were never logged.
   - *Remaining (informational):* the working copy of a project on the user's own
     disk still keeps chat history and prompts in plaintext inside the `.venice`
     package — that is the project's save format, local to the machine. Media
     transcripts are cached under `~/Library/Caches/ai.venice.videocreator/`
     (clearable in Settings → Storage).

## Data handling summary

- **API key:** macOS Keychain only; sent solely as a `Bearer` header to
  `api.venice.ai`; never logged or written to disk.
- **Projects:** `~/Documents/Venice Video Editor/`, local only.
- **Caches / models:** `~/Library/Caches/` and `~/Library/Application Support/`,
  local only, user-clearable.
- **Uploads:** occur only for user-invoked AI features, only to `api.venice.ai`.

---

*Generated by Claude Fable 5 on 2026-07-09.*

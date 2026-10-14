# Maintainer Notes

Context and non-obvious decisions for anyone (including a returning AI assistant) picking
this up. Read this before changing the menu bar rendering, the auth path, or the polling.

## What it is

A native macOS menu bar app (SwiftUI `MenuBarExtra`, no Xcode project — pure SwiftPM) that
shows Claude Code subscription **limit usage** in the menu bar: the rolling 5-hour session
window and the 7-day weekly window, with reset times and a color-coded ring.

## Architecture

Two targets, kept deliberately separate:

- **`ClaudeUsageCore`** — pure logic, **no SwiftUI/AppKit import**, fully unit-tested.
  - `DateParse` — lenient ISO8601 (`resets_at` has 6-digit fractional seconds + offset).
  - `Format` — countdown ("2h 13m", "<1m", "now").
  - `Palette` — percent + API `severity` → `RingColor` (green/amber/red).
  - `UsageParser` — decodes `/api/oauth/usage` JSON → `UsageSnapshot`.
  - `KeychainReader` — reads the token **and its expiry** as a `ClaudeCredential`; pure
    `credential(fromJSON:)` + `readCredential()` I/O (via `/usr/bin/security`, see gotcha 5;
    `SecItemCopyMatching` only as fallback).
  - `UsageClient` (`UsageFetching`) — HTTP call + error mapping (401 / 429 / network / decode).
  - `Reducer` — pure `(Result, previous) → UsageState` (loading/ok/stale/needsAuth).
  - `UsageStore` — `@MainActor @Observable`; owns single-flight refresh, watchdog, polling,
    retry deadlines, and snapshot persistence.
  - `SettingsKeys` / `RefreshInterval` / `MenuBarTextColor` — UserDefaults keys + enums.
- **`ClaudeUsage`** — the executable: SwiftUI views + `@main` scene + AppKit glue
  (`MenuBarLabel`, `RingView`, `DropdownView`, `SettingsView`, `LoginItem`,
  `ConnectivityMonitor`, `ClaudeUsageApp`).

Data flow: `UsageStore` polls every N seconds → `UsageClient.fetch()` reads the Keychain
token and calls the endpoint → `Reducer` maps the result into `UsageState` → the views
render off `store.state`.

## Data source

`GET https://api.anthropic.com/api/oauth/usage`
Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`.
Token: macOS Keychain generic-password, service **`Claude Code-credentials`**, JSON payload,
fields `claudeAiOauth.accessToken` and `claudeAiOauth.expiresAt`. Claude Code creates and
refreshes it; this app only reads it (never manages OAuth) and skips the request outright
once `expiresAt` has passed — see gotcha 7. Response has `five_hour`/`seven_day` objects and a richer `limits[]`
array. The parser uses `weekly_all` for all-model weekly usage and falls back to `seven_day`;
`weekly_scoped` entries are shown separately using `scope.model.display_name`. Credit amounts
are in **minor units** — divide `monthly_limit` /
`used_credits` by `10^decimal_places` (5000 → $50.00).

## The gotchas (these each cost real debugging time)

1. **No XCTest / Swift Testing under Command Line Tools.** Both require Xcode. Tests are a
   hand-rolled harness (`TestKit`) in an **executable** target, run with
   `swift run ClaudeUsageCoreTests`. Each area adds `Checks_<Name>.swift` with a
   `func <name>Checks()` wired into `main.swift` before `t.finish()`. Do **not** reintroduce
   `import XCTest` — it won't compile here.

2. **`MenuBarExtra` won't reliably render a multi-element SwiftUI label** (custom shapes /
   several Text runs collapse to one). `MenuBarLabel` therefore rasterizes the composed view
   into a single `NSImage`. Two-image HStack labels also don't work (the label gets flattened
   and template-tinting is lost). Keep it one image.

3. **Menu bar text color can't be auto-detected in the wallpaper-darkened case.** In light
   mode with a dark desktop picture, the menu bar uses white text but `NSApp.effectiveAppearance`
   still reports light. A template image (`isTemplate = true`) tints correctly but makes the
   ring monochrome. Resolution: the image is **non-template** (keeps the colored ring) and the
   text color is a user setting — `MenuBarTextColor` = Automatic/Light/Dark (`SettingsKeys.menuBarTextColor`).

4. **`SettingsLink` does nothing in an `LSUIElement` accessory app.** The dropdown's Settings
   button uses `NSApplication.shared.activate(ignoringOtherApps:)` + `@Environment(\.openSettings)`
   instead.

5. **Keychain re-prompts on every rebuild — the stable signing identity was NOT enough.**
   Reading the item with `SecItemCopyMatching` triggers the per-app ACL prompt, and if the
   prompt isn't answered the read **blocks**, leaving the app stuck on "Loading". The first
   fix (a stable self-signed identity, `./scripts/create-signing-cert.sh`) pinned the
   *designated requirement* so the "Always Allow" entry in the item's application list stayed
   valid — but macOS Sierra+ keychain items ALSO have a **`partition_id` ACL**, and for an app
   with **no Team ID** (any personal/self-signed build) that grant is keyed on the build's
   **cdhash**, which changes on every rebuild. So it re-prompted anyway. (Seen directly with
   `security dump-keychain -a`: entry `partition_id` = `apple-tool:, cdhash:<one stale hash>`,
   plus a graveyard of dead per-build cdhash application entries.)
   **Real fix:** `KeychainReader.readToken()` shells out to
   `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. Claude Code
   creates the item through that same Apple tool, so `/usr/bin/security` is permanently in the
   item's application list and its `apple-tool:` partition is in the partition list — the read
   never prompts, regardless of how this app is signed, and survives rebuilds *and* Claude Code
   recreating the item. `SecItemCopyMatching` remains only as a fallback. The signing scripts
   are kept for a stable code signature but are no longer load-bearing for Keychain access.
   Gated end-to-end check: `CLAUDE_USAGE_KEYCHAIN_IT=1 swift run ClaudeUsageCoreTests`.

6. **The endpoint rate-limits (HTTP 429) under bursty use.** Rapid rebuild/relaunch/refresh
   cycles (and manual `curl` probes) trip it; a lone request still gets 200. The client maps
   429 → `UsageError.rateLimited(retryAfter:)`. `UsageStore` honours `Retry-After` but probes
   under it on a doubling ceiling (2m, 4m, 8m, 16m, 32m, then the server's figure), because a
   lockout usually clears the moment a fresh token is in play and sitting out the full hour
   just leaves the menu bar showing day-old numbers. `Retry-After: 0` gets a 30s floor —
   without one it becomes a poll-rate spin loop. A **manual** refresh always overrides the
   backoff (one deliberate request can't stampede); automatic triggers stay gated. When
   debugging, **don't** spam the endpoint — you'll rate-limit the app you're testing.

7. **An expired access token is what actually caused the "stuck on cached data" bug.**
   Claude Code refreshes `claudeAiOauth.accessToken` only when it *runs*, so after an idle
   night the stored token is dead. The app used to send it on every 60s poll: three 401s in
   a row earned a 429 with `Retry-After: 3600`, and the dropdown sat on 10-hour-old numbers
   saying "retrying in 48m" — every single morning. `KeychainReader` now also reads
   `claudeAiOauth.expiresAt` (**milliseconds** since the epoch; seconds and junk are handled),
   and `UsageClient` fails fast with `UsageError.tokenExpired` **without making a request**.
   That error carries no backoff — the check is a local Keychain read — so polling continues
   (at ≤30s) and the app recovers on its own within half a minute of the user running Claude
   Code. A genuine 401/403 (token rejected despite looking live) now backs off 2m → 30m
   instead of hammering. Do **not** "fix" this by refreshing the OAuth token here: refresh
   tokens rotate, and racing Claude Code for one would sign the user out of Claude Code.

8. **Refresh triggers.** `AppRuntime` starts polling from `applicationDidFinishLaunching`,
   independent of SwiftUI view creation. Dropdown open, reconnect, wake, and manual refresh
   all enter the same single-flight coordinator; the runtime stops them during termination.

9. **Swift 5 language mode** (tools 5.9). Sendable issues are warnings, not errors, but the
   build is kept warning-free (closures marked `@Sendable`, model types `Sendable`).

## Build / run / test

```sh
swift build                        # compile
swift run ClaudeUsageCoreTests     # tests (currently 99 checks)
./scripts/create-signing-cert.sh   # ONE-TIME: optional stable self-signed identity
./scripts/make-app.sh              # build + bundle + sign → "Claude Usage.app"
cp -R "Claude Usage.app" /Applications/
```

`make-app.sh` reads the release binary path via `swift build -c release --show-bin-path`,
assembles the `.app` (Info.plist sets `LSUIElement`), and signs it — with the
`Claude Usage Self-Signed` identity when present, else ad-hoc.

## History / process

Built spec-first: `docs/superpowers/specs/` (design) → `docs/superpowers/plans/`
(step-by-step implementation plan) → subagent-driven TDD, task by task, with a final
whole-branch review. Those two docs are the fullest description of intent and the task
breakdown if you need the "why" behind a piece.

## Desktop-app use: token keep-alive (2026-10-14)

The Claude desktop app does not renew the `Claude Code-credentials` Keychain token; only the
CLI does. `scripts/token-keepalive.sh`, installed as a launchd agent by
`scripts/install-keepalive.sh` (every 5 min + at login), renews it when under 10 min remain:
`claude auth status` first, then a one-word Haiku prompt as fallback. Log:
`~/Library/Logs/claude-usage-token-keepalive.log`.

- `claude setup-token` tokens do NOT work for the usage endpoint: 403 `oauth_scope_insufficient`
  (needs `user:profile`).
- Building with Command Line Tools 27 + the macOS 27 SDK fails (`SwiftUIMacros` plugin not
  found for `@State`). Workaround: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/make-app.sh`.

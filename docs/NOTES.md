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
  - `KeychainReader` — reads the token; pure `token(fromJSON:)` + `readToken()` I/O
    (via `/usr/bin/security`, see gotcha 5; `SecItemCopyMatching` only as fallback).
  - `UsageClient` (`UsageFetching`) — HTTP call + error mapping (401 / 429 / network / decode).
  - `Reducer` — pure `(Result, previous) → UsageState` (loading/ok/stale/needsAuth).
  - `UsageStore` — `@MainActor @Observable`; owns the poll loop + backoff.
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
field `claudeAiOauth.accessToken`. Claude Code creates and refreshes it; this app only reads
it (never manages OAuth). Response has `five_hour`/`seven_day` objects and a richer `limits[]`
array; parser prefers `limits[]` (weekly = **max** percent across the weekly group), falls
back to the objects. Credit amounts are in **minor units** — divide `monthly_limit` /
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
   429 → `UsageError.rateLimited(retryAfter:)`, and `UsageStore` backs off (60–600s, honoring
   `Retry-After`) instead of hammering. When debugging, **don't** spam the endpoint — you'll
   rate-limit the app you're testing.

7. **Refresh triggers.** Polling runs from `.task` on the label (so it starts at launch, since
   the `.window`-style content view is lazy). Also refreshes on dropdown open, on network
   reconnect (`ConnectivityMonitor` / `NWPathMonitor`), and on wake (`NSWorkspace.didWakeNotification`).

8. **Swift 5 language mode** (tools 5.9). Sendable issues are warnings, not errors, but the
   build is kept warning-free (closures marked `@Sendable`, model types `Sendable`).

## Build / run / test

```sh
swift build                        # compile
swift run ClaudeUsageCoreTests     # tests (currently 49 checks)
./scripts/create-signing-cert.sh   # ONE-TIME: stable self-signed identity (durable Keychain grant)
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

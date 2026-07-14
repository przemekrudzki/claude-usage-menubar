# Claude Usage Menu Bar — Design

**Date:** 2026-07-07
**Status:** Approved (design), pending implementation plan

## Purpose

A native macOS menu bar app that shows, at a glance, how much of the user's Claude
Code (Max plan) subscription usage limits are consumed — primarily the rolling
5-hour session window and the 7-day weekly window. This is *limit tracking*
("am I about to be rate-limited?"), not token/cost accounting.

Existing third-party apps show token counts and dollar estimates computed from local
transcript files. That is the wrong signal. This app shows the same numbers the
in-app `/usage` command shows, pulled from the same authenticated endpoint.

## Data source (verified)

`GET https://api.anthropic.com/api/oauth/usage`

Headers:
- `Authorization: Bearer <accessToken>`
- `anthropic-beta: oauth-2025-04-20`
- `Content-Type: application/json`

The bearer token is read from the macOS Keychain generic-password item created by
Claude Code:
- Service: `Claude Code-credentials`
- Payload: JSON; token at `claudeAiOauth.accessToken`

**Verified live response shape** (fields we use):

```json
{
  "five_hour": { "utilization": 38.0, "resets_at": "2026-07-07T19:40:00Z" },
  "seven_day": { "utilization": 19.0, "resets_at": "2026-07-11T08:00:00Z" },
  "extra_usage": {
    "is_enabled": true, "monthly_limit": 5000, "used_credits": 0.0,
    "currency": "CAD", "decimal_places": 2
  },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 38, "severity": "normal", "resets_at": "…", "is_active": true },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 19, "severity": "normal", "resets_at": "…", "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 19, "severity": "normal", "resets_at": "…", "scope": { "model": { "id": null, "display_name": "Fable" } } }
  ]
}
```

Parsing rules:
- **Session %** = `limits[]` entry with `kind == "session"` (fallback `five_hour.utilization`).
- **All-model weekly %** = `limits[]` entry with `kind == "weekly_all"` (fallback `seven_day.utilization`).
- **Model weekly %** = each `limits[]` entry with `kind == "weekly_scoped"`, labeled from `scope.model.display_name` and shown separately in the dropdown.
- **Reset times** from the corresponding `resets_at`.
- **Severity** from the matching `limits[]` entry, used to drive ring color.
- **Extra credits** from `extra_usage` when `is_enabled`.

### Auth model

The app **never manages OAuth itself**. On each poll it re-reads the current token
from the Keychain, so it automatically benefits from Claude Code's own background
token refresh. If the token is missing or the endpoint returns 401, the app shows a
"sign in to Claude Code" state rather than attempting a refresh.

First Keychain read triggers a one-time macOS prompt ("app wants to use
Claude Code-credentials"); user clicks **Always Allow** once. Accepted tradeoff.

## Tech stack

- **SwiftUI `MenuBarExtra`** app, macOS 14+ target. No third-party dependencies.
- Ring drawn in SwiftUI and rendered to the menu bar image (`ImageRenderer` → `NSImage`),
  updated on each poll so it can color-shift.
- Dropdown and Settings are plain SwiftUI views.
- Networking via `URLSession` (async/await); JSON via `Codable`.
- Keychain read via Security.framework (`SecItemCopyMatching`).
- Launch at login via `SMAppService.mainApp.register()`.

Rejected: AppKit `NSStatusItem` (more boilerplate, unneeded); Electron / Tauri /
Python-rumps (heavy, non-native — the very thing that makes existing apps feel bad).

## Menu bar (always-visible)

Default: `◔ 38% · 2h13m · 7d 19%`

- **Ring gauge** — circular progress of the 5-hour session %, color by severity.
- **5-hour %**
- **Countdown** to session reset (e.g. `2h13m`).
- **Weekly %** (e.g. `7d 19%`).

Each of the four elements is individually toggleable in Settings. The dropdown always
shows the full breakdown regardless of these toggles.

### Ring color

Driven by the API `severity` field where present. Fallback thresholds by percent:
- green `< 70%`
- amber `70–89%`
- red `>= 90%`

## Dropdown

- **5-hour session** — ring + `NN% used`, `resets at HH:MM (in Xh Ym)`
- **7-day** — bar + `NN% used`, `resets <weekday Mon DD>`
- **Extra usage credits** (only if `extra_usage.is_enabled`) — `<used> / <limit> <currency>`
- Divider
- `Last updated Ns ago` + **Refresh now** button
- **Settings…** (also ⌘,)
- **Quit**

## Settings window

- ☑ Ring gauge
- ☑ 5-hour %
- ☑ Countdown to reset
- ☑ Weekly %
- Refresh interval: `30s` / `60s` (default) / `5m`
- ☑ Launch at login

Persisted via `@AppStorage` (UserDefaults). Defaults: all display toggles on, 60s,
launch-at-login on (registered on first run).

Explicitly out of scope (YAGNI): color themes, custom fonts, per-window layout,
notifications/alerts, historical charts, cost/token accounting.

## Behavior & states

- **Poll** every `refreshInterval` seconds; also refresh immediately when the dropdown
  opens and when the app wakes from sleep.
- **OK** — live numbers, ring colored by severity.
- **Loading** (first launch, no data yet) — hollow pulsing ring, `Loading…`.
- **Token missing / 401** — hollow dimmed ring; dropdown: *"Sign in to Claude Code to
  see usage."* No error dialog.
- **Network error / offline** — show last-known values **dimmed** with
  `stale · couldn't reach Anthropic`; never blank out or show 0%.

State model (single source of truth):

```
enum UsageState {
  case loading
  case ok(UsageSnapshot)
  case stale(UsageSnapshot, since: Date)   // last good data, fetch failing
  case needsAuth                            // token missing/expired/401
}
```

`UsageSnapshot` holds session%, all-model weekly%, model-scoped weekly windows, reset dates,
severity, optional credits, and fetchedAt.

## Components

- **KeychainReader** — reads `Claude Code-credentials`, extracts `accessToken`. Pure,
  testable given a JSON blob (parse split from Keychain I/O).
- **UsageClient** — builds the request, calls the endpoint, decodes into `UsageSnapshot`.
  Maps 401 → needsAuth, network failure → thrown error.
- **UsageStore** (`@Observable`/ObservableObject) — owns the timer, current `UsageState`,
  and the last good snapshot; exposes `refresh()`.
- **MenuBarLabel** — renders ring + text per Settings toggles into the bar image.
- **DropdownView** — the breakdown panel.
- **SettingsView** — the toggles.
- **LoginItem** — thin wrapper over `SMAppService`.
- **AppMain** — `MenuBarExtra` scene wiring the above.

## Testing

- **KeychainReader**: unit test the JSON parse (valid, missing key, malformed) against
  fixture blobs — no Keychain access in tests.
- **UsageClient decode**: unit test decoding the verified response fixture → correct
  session%, all-model and model-scoped weekly percentages, reset dates, credits; and a
  no-`limits[]` fallback fixture.
- **State mapping**: 401 → needsAuth; thrown network error while holding a snapshot →
  stale; success → ok.
- **Severity → color** mapping table.
- **Countdown formatting** (e.g. 2h13m, <1m, 0).
- Manual: run against the live endpoint; simulate offline; sign out to hit needsAuth.

## Distribution

Personal use: build with Xcode/`xcodebuild`, ad-hoc sign, drag to `/Applications`.
Launch-at-login registers on first run. (No App Store, no notarization for personal use;
Gatekeeper first-open handled by right-click → Open if unsigned.)

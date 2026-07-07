# Claude Usage Menu Bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app that shows current Claude Code subscription
usage (rolling 5-hour session % + 7-day weekly %, with reset times) at a glance.

**Architecture:** SwiftUI `MenuBarExtra` app. A `UsageStore` polls the authenticated
`GET /api/oauth/usage` endpoint every N seconds using the OAuth token read from the
macOS Keychain (`Claude Code-credentials`), decodes it into a `UsageSnapshot`, and a
pure reducer maps fetch results into a `UsageState` that drives the ring, label, and
dropdown. Pure logic lives in a `ClaudeUsageCore` library target (unit-tested); SwiftUI
views + `@main` live in the `ClaudeUsage` executable target. Build via SwiftPM; a shell
script wraps the binary into a `.app` bundle and ad-hoc signs it.

**Tech Stack:** Swift 6 / SwiftUI, Swift Package Manager (no Xcode), `URLSession`,
`Codable`, Security.framework (Keychain), `SMAppService` (launch at login), XCTest.

## Global Constraints

- macOS deployment target: **macOS 14** (`.macOS(.v14)`) — `MenuBarExtra` requires 13+, we target 14.
- **No third-party dependencies.** Standard library + Apple frameworks only.
- **No Xcode.** Build with `swift build` / `swift test`. App bundle assembled by `scripts/make-app.sh`.
- Endpoint: `GET https://api.anthropic.com/api/oauth/usage` with headers
  `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`.
- Keychain item: service **`Claude Code-credentials`**, JSON payload, token at `claudeAiOauth.accessToken`.
- The app **never** manages OAuth — it re-reads the Keychain each poll and rides Claude Code's refresh.
- Pure logic (models, parsing, formatting, reducer, palette) goes in `ClaudeUsageCore` and must **not import SwiftUI** so it stays unit-testable under CLT.
- Bundle identifier: `com.przemek.ClaudeUsageMenuBar`. App display name: `Claude Usage`.
- Work happens in `~/my-projects/claude-usage-menubar/`. It is already a git repo with the design spec committed.

---

## File Structure

```
claude-usage-menubar/
  Package.swift
  Sources/
    ClaudeUsageCore/                 # pure logic — no SwiftUI
      Models.swift                   # UsageWindow, Credits, UsageSnapshot, UsageState, UsageError, RingColor
      DateParse.swift                # lenient ISO8601 parsing
      Format.swift                   # countdown formatting
      Palette.swift                  # percent+severity -> RingColor
      UsageParser.swift              # Data -> UsageSnapshot
      KeychainReader.swift           # token from JSON + Keychain I/O
      Reducer.swift                  # (Result, previous) -> UsageState
      UsageFetching.swift            # protocol
      UsageClient.swift              # URLSession fetch -> Result
      UsageStore.swift               # @Observable: timer, state, refresh()
      SettingsKeys.swift             # UserDefaults key constants + defaults
    ClaudeUsage/                     # executable — SwiftUI + @main
      ClaudeUsageApp.swift           # @main MenuBarExtra scene
      RingView.swift                 # circular gauge shape
      MenuBarLabel.swift             # ring + text per settings -> label view
      DropdownView.swift             # breakdown panel
      SettingsView.swift             # toggles
      LoginItem.swift                # SMAppService wrapper
      ColorMap.swift                 # RingColor -> SwiftUI Color
  Tests/
    ClaudeUsageCoreTests/
      Fixtures/
        usage_full.json
        usage_no_limits.json
      DateParseTests.swift
      FormatTests.swift
      PaletteTests.swift
      UsageParserTests.swift
      KeychainReaderTests.swift
      ReducerTests.swift
      UsageStoreTests.swift
  scripts/
    make-app.sh
    Info.plist
```

---

### Task 1: Package scaffold + green test loop

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeUsageCore/Models.swift`
- Create: `Sources/ClaudeUsage/ClaudeUsageApp.swift`
- Test: `Tests/ClaudeUsageCoreTests/DateParseTests.swift` (placeholder, replaced in Task 2)

**Interfaces:**
- Consumes: nothing.
- Produces: three targets — library `ClaudeUsageCore`, executable `ClaudeUsage`, test target `ClaudeUsageCoreTests`. Establishes that `swift build` and `swift test` both work.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeUsageCore"),
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["ClaudeUsageCore"]
        ),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: Create the Fixtures dir so `.copy` resolves**

```bash
mkdir -p Tests/ClaudeUsageCoreTests/Fixtures
echo '{}' > Tests/ClaudeUsageCoreTests/Fixtures/.keep.json
```

- [ ] **Step 3: Write a minimal placeholder in `Models.swift`**

```swift
import Foundation

public enum ClaudeUsageCore {
    public static let version = "0.1.0"
}
```

- [ ] **Step 4: Write a minimal `@main` so the executable target compiles**

`Sources/ClaudeUsage/ClaudeUsageApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeUsageApp: App {
    var body: some Scene {
        MenuBarExtra("Claude Usage") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
```

- [ ] **Step 5: Write a trivial passing test**

`Tests/ClaudeUsageCoreTests/DateParseTests.swift`:

```swift
import XCTest
@testable import ClaudeUsageCore

final class DateParseTests: XCTestCase {
    func testScaffold() {
        XCTAssertEqual(ClaudeUsageCore.version, "0.1.0")
    }
}
```

- [ ] **Step 6: Build and test**

Run: `swift build && swift test`
Expected: `Build complete!` then `Test Suite ... passed`, 1 test, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "Scaffold SwiftPM package with core lib, executable, and test target"
```

---

### Task 2: Lenient ISO8601 date parsing

**Files:**
- Create: `Sources/ClaudeUsageCore/DateParse.swift`
- Test: `Tests/ClaudeUsageCoreTests/DateParseTests.swift` (replace placeholder)

**Interfaces:**
- Produces: `enum DateParse { static func iso(_ s: String) -> Date? }` — parses the endpoint's
  `resets_at` strings, which carry 6-digit fractional seconds and a `+00:00` offset
  (e.g. `"2026-07-07T19:40:00.384593+00:00"`). Fractional seconds are stripped before parsing
  (we only render minute precision).

- [ ] **Step 1: Replace `DateParseTests.swift` with real tests**

```swift
import XCTest
@testable import ClaudeUsageCore

final class DateParseTests: XCTestCase {
    func testParsesFractionalOffsetTimestamp() {
        let d = DateParse.iso("2026-07-07T19:40:00.384593+00:00")
        XCTAssertNotNil(d)
        // 2026-07-07T19:40:00Z == 1783626000 seconds since epoch
        XCTAssertEqual(d!.timeIntervalSince1970, 1783626000, accuracy: 1)
    }

    func testParsesPlainZuluTimestamp() {
        let d = DateParse.iso("2026-07-11T08:00:00+00:00")
        XCTAssertNotNil(d)
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(DateParse.iso("not-a-date"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DateParseTests`
Expected: FAIL — `type 'DateParse' has no member 'iso'` (compile error).

- [ ] **Step 3: Implement `DateParse`**

```swift
import Foundation

public enum DateParse {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO8601 timestamps, tolerating variable-length fractional seconds
    /// by stripping them (we only need minute precision).
    public static func iso(_ s: String) -> Date? {
        let noFraction = s.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        return formatter.date(from: noFraction)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DateParseTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageCore/DateParse.swift Tests/ClaudeUsageCoreTests/DateParseTests.swift
git commit -m "Add lenient ISO8601 date parsing"
```

---

### Task 3: Countdown formatting

**Files:**
- Create: `Sources/ClaudeUsageCore/Format.swift`
- Test: `Tests/ClaudeUsageCoreTests/FormatTests.swift`

**Interfaces:**
- Produces: `enum Format { static func countdown(to date: Date, now: Date) -> String }`.
  Renders `"2h 13m"`, `"13m"`, `"<1m"` for near-zero, and `"now"` when the target is in the past.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeUsageCore

final class FormatTests: XCTestCase {
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    func testHoursAndMinutes() {
        let now = at(0)
        XCTAssertEqual(Format.countdown(to: at(2*3600 + 13*60), now: now), "2h 13m")
    }
    func testMinutesOnly() {
        XCTAssertEqual(Format.countdown(to: at(13*60), now: at(0)), "13m")
    }
    func testSubMinute() {
        XCTAssertEqual(Format.countdown(to: at(30), now: at(0)), "<1m")
    }
    func testPast() {
        XCTAssertEqual(Format.countdown(to: at(0), now: at(60)), "now")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter FormatTests`
Expected: FAIL — no member `countdown`.

- [ ] **Step 3: Implement `Format`**

```swift
import Foundation

public enum Format {
    public static func countdown(to date: Date, now: Date) -> String {
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        if secs < 60 { return "<1m" }
        let mins = secs / 60
        let h = mins / 60
        let m = mins % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FormatTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageCore/Format.swift Tests/ClaudeUsageCoreTests/FormatTests.swift
git commit -m "Add countdown formatting"
```

---

### Task 4: Domain models

**Files:**
- Modify: `Sources/ClaudeUsageCore/Models.swift`
- Test: (covered indirectly by later tasks; no dedicated test — these are plain data types)

**Interfaces:**
- Produces the shared vocabulary every later task consumes:

```swift
public struct UsageWindow: Equatable {
    public let percent: Double
    public let resetsAt: Date
    public let severity: String
    public init(percent: Double, resetsAt: Date, severity: String) {
        self.percent = percent; self.resetsAt = resetsAt; self.severity = severity
    }
}

public struct Credits: Equatable {
    public let used: Double
    public let limit: Double
    public let currency: String
    public let decimalPlaces: Int
    public init(used: Double, limit: Double, currency: String, decimalPlaces: Int) {
        self.used = used; self.limit = limit; self.currency = currency; self.decimalPlaces = decimalPlaces
    }
}

public struct UsageSnapshot: Equatable {
    public let session: UsageWindow
    public let weekly: UsageWindow
    public let credits: Credits?
    public let fetchedAt: Date
    public init(session: UsageWindow, weekly: UsageWindow, credits: Credits?, fetchedAt: Date) {
        self.session = session; self.weekly = weekly; self.credits = credits; self.fetchedAt = fetchedAt
    }
}

public enum UsageState: Equatable {
    case loading
    case ok(UsageSnapshot)
    case stale(UsageSnapshot, since: Date)
    case needsAuth
}

public enum UsageError: Error, Equatable {
    case noToken
    case unauthorized
    case network(String)
    case decoding(String)
}

public enum RingColor: Equatable { case green, amber, red }
```

- [ ] **Step 1: Replace the placeholder body of `Models.swift`**

Keep the version constant and add all types above:

```swift
import Foundation

public enum ClaudeUsageCore {
    public static let version = "0.1.0"
}

// ... (paste all the types from the Interfaces block above)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run full test suite (nothing should break)**

Run: `swift test`
Expected: PASS (7 tests so far).

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeUsageCore/Models.swift
git commit -m "Add domain models (UsageWindow, UsageSnapshot, UsageState, UsageError, RingColor)"
```

---

### Task 5: Ring color palette

**Files:**
- Create: `Sources/ClaudeUsageCore/Palette.swift`
- Test: `Tests/ClaudeUsageCoreTests/PaletteTests.swift`

**Interfaces:**
- Produces: `enum Palette { static func ring(percent: Double, severity: String) -> RingColor }`.
  Uses the API `severity` when it is a recognized escalated value (`"warning"` → amber,
  `"critical"`/`"exceeded"` → red); otherwise falls back to percent thresholds
  (`< 70` green, `70..<90` amber, `>= 90` red).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeUsageCore

final class PaletteTests: XCTestCase {
    func testThresholdsWhenSeverityNormal() {
        XCTAssertEqual(Palette.ring(percent: 10, severity: "normal"), .green)
        XCTAssertEqual(Palette.ring(percent: 75, severity: "normal"), .amber)
        XCTAssertEqual(Palette.ring(percent: 95, severity: "normal"), .red)
    }
    func testSeverityOverridesLowPercent() {
        XCTAssertEqual(Palette.ring(percent: 5, severity: "warning"), .amber)
        XCTAssertEqual(Palette.ring(percent: 5, severity: "critical"), .red)
    }
    func testUnknownSeverityFallsBackToThreshold() {
        XCTAssertEqual(Palette.ring(percent: 10, severity: "weird"), .green)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaletteTests`
Expected: FAIL — no member `ring`.

- [ ] **Step 3: Implement `Palette`**

```swift
import Foundation

public enum Palette {
    public static func ring(percent: Double, severity: String) -> RingColor {
        switch severity.lowercased() {
        case "warning": return .amber
        case "critical", "exceeded": return .red
        default: break
        }
        switch percent {
        case ..<70: return .green
        case 70..<90: return .amber
        default: return .red
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter PaletteTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageCore/Palette.swift Tests/ClaudeUsageCoreTests/PaletteTests.swift
git commit -m "Add ring color palette (severity + percent thresholds)"
```

---

### Task 6: Usage response parser

**Files:**
- Create: `Sources/ClaudeUsageCore/UsageParser.swift`
- Create: `Tests/ClaudeUsageCoreTests/Fixtures/usage_full.json`
- Create: `Tests/ClaudeUsageCoreTests/Fixtures/usage_no_limits.json`
- Test: `Tests/ClaudeUsageCoreTests/UsageParserTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `UsageWindow`, `Credits`, `DateParse`.
- Produces: `enum UsageParser { static func snapshot(from data: Data, now: Date) throws -> UsageSnapshot }`.
  Parsing rules: session = `limits[]` where `kind == "session"` (fallback `five_hour`);
  weekly = `limits[]` where `group == "weekly"` with the highest `percent` (fallback `seven_day`);
  credits from `extra_usage` only when `is_enabled == true`. Throws `UsageError.decoding` on
  missing required windows. `now` is stored as `fetchedAt`.

- [ ] **Step 1: Create `usage_full.json` fixture** (trimmed real response)

```json
{
  "five_hour": { "utilization": 38.0, "resets_at": "2026-07-07T19:40:00.384593+00:00" },
  "seven_day": { "utilization": 19.0, "resets_at": "2026-07-11T08:00:00.384617+00:00" },
  "extra_usage": {
    "is_enabled": true, "monthly_limit": 5000, "used_credits": 12.5,
    "utilization": null, "currency": "CAD", "decimal_places": 2
  },
  "limits": [
    { "kind": "session",       "group": "session", "percent": 38, "severity": "normal", "resets_at": "2026-07-07T19:40:00.384593+00:00", "is_active": true },
    { "kind": "weekly_all",    "group": "weekly",  "percent": 19, "severity": "normal", "resets_at": "2026-07-11T08:00:00.384617+00:00", "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly",  "percent": 22, "severity": "warning", "resets_at": "2026-07-11T08:00:00.384934+00:00" }
  ]
}
```

- [ ] **Step 2: Create `usage_no_limits.json` fixture** (fallback path — no `limits[]`, no credits)

```json
{
  "five_hour": { "utilization": 50.0, "resets_at": "2026-07-07T19:40:00+00:00" },
  "seven_day": { "utilization": 25.0, "resets_at": "2026-07-11T08:00:00+00:00" },
  "extra_usage": { "is_enabled": false }
}
```

- [ ] **Step 3: Write the failing tests**

```swift
import XCTest
@testable import ClaudeUsageCore

final class UsageParserTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        return try Data(contentsOf: XCTUnwrap(url))
    }
    private let now = Date(timeIntervalSince1970: 1000)

    func testParsesFullResponse() throws {
        let snap = try UsageParser.snapshot(from: load("usage_full"), now: now)
        XCTAssertEqual(snap.session.percent, 38)
        XCTAssertEqual(snap.session.severity, "normal")
        // weekly picks the highest percent in the weekly group (22 > 19)
        XCTAssertEqual(snap.weekly.percent, 22)
        XCTAssertEqual(snap.weekly.severity, "warning")
        XCTAssertEqual(snap.credits?.used, 12.5)
        XCTAssertEqual(snap.credits?.limit, 5000)
        XCTAssertEqual(snap.credits?.currency, "CAD")
        XCTAssertEqual(snap.fetchedAt, now)
    }

    func testFallsBackWhenNoLimitsArray() throws {
        let snap = try UsageParser.snapshot(from: load("usage_no_limits"), now: now)
        XCTAssertEqual(snap.session.percent, 50)
        XCTAssertEqual(snap.weekly.percent, 25)
        XCTAssertNil(snap.credits)   // extra_usage disabled
    }

    func testThrowsDecodingOnEmptyObject() {
        XCTAssertThrowsError(try UsageParser.snapshot(from: Data("{}".utf8), now: now))
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `swift test --filter UsageParserTests`
Expected: FAIL — no member `snapshot`.

- [ ] **Step 5: Implement `UsageParser`**

```swift
import Foundation

public enum UsageParser {
    public static func snapshot(from data: Data, now: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding("root is not an object")
        }
        let limits = root["limits"] as? [[String: Any]] ?? []

        let session = try window(
            fromLimits: limits.first { ($0["kind"] as? String) == "session" },
            fallbackObject: root["five_hour"] as? [String: Any],
            label: "session"
        )

        let weeklyEntries = limits.filter { ($0["group"] as? String) == "weekly" }
        let topWeekly = weeklyEntries.max { percent($0) < percent($1) }
        let weekly = try window(
            fromLimits: topWeekly,
            fallbackObject: root["seven_day"] as? [String: Any],
            label: "weekly"
        )

        let credits = parseCredits(root["extra_usage"] as? [String: Any])
        return UsageSnapshot(session: session, weekly: weekly, credits: credits, fetchedAt: now)
    }

    private static func percent(_ e: [String: Any]) -> Double {
        (e["percent"] as? NSNumber)?.doubleValue ?? 0
    }

    private static func window(fromLimits limit: [String: Any]?,
                               fallbackObject fallback: [String: Any]?,
                               label: String) throws -> UsageWindow {
        if let l = limit,
           let resetStr = l["resets_at"] as? String, let reset = DateParse.iso(resetStr) {
            let pct = (l["percent"] as? NSNumber)?.doubleValue ?? 0
            let sev = (l["severity"] as? String) ?? "normal"
            return UsageWindow(percent: pct, resetsAt: reset, severity: sev)
        }
        if let f = fallback,
           let util = (f["utilization"] as? NSNumber)?.doubleValue,
           let resetStr = f["resets_at"] as? String, let reset = DateParse.iso(resetStr) {
            return UsageWindow(percent: util, resetsAt: reset, severity: "normal")
        }
        throw UsageError.decoding("missing \(label) window")
    }

    private static func parseCredits(_ e: [String: Any]?) -> Credits? {
        guard let e, (e["is_enabled"] as? Bool) == true else { return nil }
        let used = (e["used_credits"] as? NSNumber)?.doubleValue ?? 0
        let limit = (e["monthly_limit"] as? NSNumber)?.doubleValue ?? 0
        let currency = (e["currency"] as? String) ?? "USD"
        let places = (e["decimal_places"] as? NSNumber)?.intValue ?? 2
        return Credits(used: used, limit: limit, currency: currency, decimalPlaces: places)
    }
}
```

- [ ] **Step 6: Run to verify pass**

Run: `swift test --filter UsageParserTests`
Expected: PASS, 3 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeUsageCore/UsageParser.swift Tests/ClaudeUsageCoreTests/UsageParserTests.swift Tests/ClaudeUsageCoreTests/Fixtures/usage_full.json Tests/ClaudeUsageCoreTests/Fixtures/usage_no_limits.json
git commit -m "Add usage response parser with limits[] and fallback paths"
```

---

### Task 7: Keychain token reader

**Files:**
- Create: `Sources/ClaudeUsageCore/KeychainReader.swift`
- Test: `Tests/ClaudeUsageCoreTests/KeychainReaderTests.swift`

**Interfaces:**
- Consumes: `UsageError`.
- Produces:
  - `static func KeychainReader.token(fromJSON data: Data) throws -> String` — pure parse; extracts
    `claudeAiOauth.accessToken`; throws `UsageError.noToken` if absent. (Unit-tested.)
  - `static func KeychainReader.readToken() throws -> String` — reads generic-password item with
    service `Claude Code-credentials` from the Keychain, then calls `token(fromJSON:)`. (Not unit-tested;
    exercised manually — touches the real Keychain.)

- [ ] **Step 1: Write the failing test (pure parse only)**

```swift
import XCTest
@testable import ClaudeUsageCore

final class KeychainReaderTests: XCTestCase {
    func testExtractsAccessToken() throws {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r"}}"#.utf8)
        XCTAssertEqual(try KeychainReader.token(fromJSON: json), "tok-123")
    }
    func testThrowsWhenMissing() {
        let json = Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8)
        XCTAssertThrowsError(try KeychainReader.token(fromJSON: json)) {
            XCTAssertEqual($0 as? UsageError, .noToken)
        }
    }
    func testThrowsOnMalformed() {
        XCTAssertThrowsError(try KeychainReader.token(fromJSON: Data("nonsense".utf8)))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter KeychainReaderTests`
Expected: FAIL — no member `token(fromJSON:)`.

- [ ] **Step 3: Implement `KeychainReader`**

```swift
import Foundation
import Security

public enum KeychainReader {
    static let service = "Claude Code-credentials"

    public static func token(fromJSON data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { throw UsageError.noToken }
        return token
    }

    public static func readToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw UsageError.noToken
        }
        return try token(fromJSON: data)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter KeychainReaderTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageCore/KeychainReader.swift Tests/ClaudeUsageCoreTests/KeychainReaderTests.swift
git commit -m "Add Keychain token reader (pure parse + Security.framework read)"
```

---

### Task 8: State reducer

**Files:**
- Create: `Sources/ClaudeUsageCore/Reducer.swift`
- Test: `Tests/ClaudeUsageCoreTests/ReducerTests.swift`

**Interfaces:**
- Consumes: `UsageState`, `UsageSnapshot`, `UsageError`.
- Produces: `enum Reducer { static func map(_ result: Result<UsageSnapshot, UsageError>, previous: UsageState, now: Date) -> UsageState }`.
  Rules: success → `.ok`; `.noToken`/`.unauthorized` → `.needsAuth`; other errors → `.stale(lastSnapshot, since: now)`
  when a snapshot exists in `previous` (preserving the original `since` if already stale), else `.loading`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import ClaudeUsageCore

final class ReducerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5000)
    private func snap(_ p: Double) -> UsageSnapshot {
        let w = UsageWindow(percent: p, resetsAt: Date(timeIntervalSince1970: 9999), severity: "normal")
        return UsageSnapshot(session: w, weekly: w, credits: nil, fetchedAt: now)
    }

    func testSuccessBecomesOk() {
        XCTAssertEqual(Reducer.map(.success(snap(10)), previous: .loading, now: now), .ok(snap(10)))
    }
    func testAuthErrorBecomesNeedsAuth() {
        XCTAssertEqual(Reducer.map(.failure(.unauthorized), previous: .ok(snap(10)), now: now), .needsAuth)
        XCTAssertEqual(Reducer.map(.failure(.noToken), previous: .loading, now: now), .needsAuth)
    }
    func testNetworkErrorFromOkBecomesStale() {
        let prev = UsageState.ok(snap(10))
        XCTAssertEqual(Reducer.map(.failure(.network("x")), previous: prev, now: now),
                       .stale(snap(10), since: now))
    }
    func testNetworkErrorKeepsOriginalStaleSince() {
        let since = Date(timeIntervalSince1970: 100)
        let prev = UsageState.stale(snap(10), since: since)
        XCTAssertEqual(Reducer.map(.failure(.network("x")), previous: prev, now: now),
                       .stale(snap(10), since: since))
    }
    func testNetworkErrorWithNoDataStaysLoading() {
        XCTAssertEqual(Reducer.map(.failure(.network("x")), previous: .loading, now: now), .loading)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ReducerTests`
Expected: FAIL — no member `map`.

- [ ] **Step 3: Implement `Reducer`**

```swift
import Foundation

public enum Reducer {
    public static func map(_ result: Result<UsageSnapshot, UsageError>,
                           previous: UsageState, now: Date) -> UsageState {
        switch result {
        case .success(let snap):
            return .ok(snap)
        case .failure(let err):
            switch err {
            case .noToken, .unauthorized:
                return .needsAuth
            case .network, .decoding:
                switch previous {
                case .ok(let snap):
                    return .stale(snap, since: now)
                case .stale(let snap, let since):
                    return .stale(snap, since: since)
                case .loading, .needsAuth:
                    return .loading
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ReducerTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageCore/Reducer.swift Tests/ClaudeUsageCoreTests/ReducerTests.swift
git commit -m "Add pure state reducer for fetch results"
```

---

### Task 9: Usage client + fetching protocol

**Files:**
- Create: `Sources/ClaudeUsageCore/UsageFetching.swift`
- Create: `Sources/ClaudeUsageCore/UsageClient.swift`
- Test: `Tests/ClaudeUsageCoreTests/UsageClientTests.swift`

**Interfaces:**
- Consumes: `UsageParser`, `UsageError`, `KeychainReader`.
- Produces:
  - `protocol UsageFetching { func fetch() async -> Result<UsageSnapshot, UsageError> }`
  - `final class UsageClient: UsageFetching` with
    `init(tokenProvider: @escaping () throws -> String = { try KeychainReader.readToken() }, session: URLSession = .shared, now: @escaping () -> Date = { Date() })`.
    Maps: token throw → `.noToken`; HTTP 401 → `.unauthorized`; transport error → `.network`; parse throw → `.decoding`.

- [ ] **Step 1: Write `UsageFetching.swift`**

```swift
import Foundation

public protocol UsageFetching: Sendable {
    func fetch() async -> Result<UsageSnapshot, UsageError>
}
```

- [ ] **Step 2: Write the failing test** (error mapping via injected token provider + a stub URLProtocol)

`Tests/ClaudeUsageCoreTests/UsageClientTests.swift`:

```swift
import XCTest
@testable import ClaudeUsageCore

final class UsageClientTests: XCTestCase {
    func testNoTokenMapsToNoToken() async {
        let client = UsageClient(tokenProvider: { throw UsageError.noToken })
        let result = await client.fetch()
        XCTAssertEqual(result, .failure(.noToken))
    }

    func testUnauthorizedResponseMaps() async {
        StubURLProtocol.status = 401
        StubURLProtocol.body = Data("unauthorized".utf8)
        let client = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
        let result = await client.fetch()
        XCTAssertEqual(result, .failure(.unauthorized))
    }

    func testSuccessParsesSnapshot() async throws {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data(#"""
        {"limits":[{"kind":"session","group":"session","percent":40,"severity":"normal","resets_at":"2026-07-07T19:40:00+00:00"},
                   {"kind":"weekly_all","group":"weekly","percent":20,"severity":"normal","resets_at":"2026-07-11T08:00:00+00:00"}],
         "extra_usage":{"is_enabled":false}}
        """#.utf8)
        let client = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
        let result = await client.fetch()
        guard case .success(let snap) = result else { return XCTFail("expected success") }
        XCTAssertEqual(snap.session.percent, 40)
        XCTAssertEqual(snap.weekly.percent, 20)
    }
}

// Minimal URLProtocol stub for injecting canned responses.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter UsageClientTests`
Expected: FAIL — no type `UsageClient`.

- [ ] **Step 4: Implement `UsageClient`**

```swift
import Foundation

public final class UsageClient: UsageFetching {
    private let tokenProvider: () throws -> String
    private let session: URLSession
    private let now: () -> Date
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(tokenProvider: @escaping () throws -> String = { try KeychainReader.readToken() },
                session: URLSession = .shared,
                now: @escaping () -> Date = { Date() }) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    public func fetch() async -> Result<UsageSnapshot, UsageError> {
        let token: String
        do { token = try tokenProvider() }
        catch let e as UsageError { return .failure(e) }
        catch { return .failure(.noToken) }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                return .failure(.unauthorized)
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.network("HTTP \(http.statusCode)"))
            }
            let snap = try UsageParser.snapshot(from: data, now: now())
            return .success(snap)
        } catch let e as UsageError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter UsageClientTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeUsageCore/UsageFetching.swift Sources/ClaudeUsageCore/UsageClient.swift Tests/ClaudeUsageCoreTests/UsageClientTests.swift
git commit -m "Add usage client with error mapping and injectable session"
```

---

### Task 10: Usage store (observable, polling)

**Files:**
- Create: `Sources/ClaudeUsageCore/UsageStore.swift`
- Test: `Tests/ClaudeUsageCoreTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `UsageFetching`, `UsageState`, `Reducer`.
- Produces: `@MainActor @Observable final class UsageStore` with
  `var state: UsageState` (starts `.loading`),
  `init(fetcher: UsageFetching, now: @escaping () -> Date = { Date() })`,
  `func refresh() async` (fetch once, run reducer, update `state`),
  `func start(intervalSeconds: Double)` / `func stop()` (Task-based polling loop).

- [ ] **Step 1: Write the failing test** (drive `refresh()` with stub fetchers)

```swift
import XCTest
@testable import ClaudeUsageCore

@MainActor
final class UsageStoreTests: XCTestCase {
    struct StubFetcher: UsageFetching {
        let result: Result<UsageSnapshot, UsageError>
        func fetch() async -> Result<UsageSnapshot, UsageError> { result }
    }
    private let now = Date(timeIntervalSince1970: 42)
    private func snap(_ p: Double) -> UsageSnapshot {
        let w = UsageWindow(percent: p, resetsAt: Date(timeIntervalSince1970: 9999), severity: "normal")
        return UsageSnapshot(session: w, weekly: w, credits: nil, fetchedAt: now)
    }

    func testRefreshSuccessSetsOk() async {
        let store = UsageStore(fetcher: StubFetcher(result: .success(snap(33))), now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.state, .ok(snap(33)))
    }
    func testRefreshAuthErrorSetsNeedsAuth() async {
        let store = UsageStore(fetcher: StubFetcher(result: .failure(.unauthorized)), now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.state, .needsAuth)
    }
    func testStartsInLoading() {
        let store = UsageStore(fetcher: StubFetcher(result: .failure(.network("x"))), now: { self.now })
        XCTAssertEqual(store.state, .loading)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter UsageStoreTests`
Expected: FAIL — no type `UsageStore`.

- [ ] **Step 3: Implement `UsageStore`**

```swift
import Foundation
import Observation

@MainActor
@Observable
public final class UsageStore {
    public private(set) var state: UsageState = .loading

    private let fetcher: UsageFetching
    private let now: () -> Date
    private var pollTask: Task<Void, Never>?

    public init(fetcher: UsageFetching, now: @escaping () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.now = now
    }

    public func refresh() async {
        let result = await fetcher.fetch()
        state = Reducer.map(result, previous: state, now: now())
    }

    public func start(intervalSeconds: Double) {
        stop()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter UsageStoreTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsageCore/UsageStore.swift Tests/ClaudeUsageCoreTests/UsageStoreTests.swift
git commit -m "Add observable usage store with polling loop"
```

---

### Task 11: Settings keys + full core suite green

**Files:**
- Create: `Sources/ClaudeUsageCore/SettingsKeys.swift`
- Test: none (constants) — verified by full-suite run.

**Interfaces:**
- Produces: `enum SettingsKeys` with string constants used by SwiftUI `@AppStorage` and by the store:
  `showRing`, `showSessionPercent`, `showCountdown`, `showWeekly`, `refreshInterval`, `launchAtLogin`;
  plus `enum RefreshInterval: Double, CaseIterable { case s30 = 30, s60 = 60, m5 = 300 }`.

- [ ] **Step 1: Write `SettingsKeys.swift`**

```swift
import Foundation

public enum SettingsKeys {
    public static let showRing = "showRing"
    public static let showSessionPercent = "showSessionPercent"
    public static let showCountdown = "showCountdown"
    public static let showWeekly = "showWeekly"
    public static let refreshInterval = "refreshInterval"   // stores RefreshInterval.rawValue
    public static let launchAtLogin = "launchAtLogin"

    /// Register defaults: all display elements on, 60s refresh.
    public static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            showRing: true,
            showSessionPercent: true,
            showCountdown: true,
            showWeekly: true,
            refreshInterval: RefreshInterval.s60.rawValue,
        ])
    }
}

public enum RefreshInterval: Double, CaseIterable {
    case s30 = 30, s60 = 60, m5 = 300
    public var label: String {
        switch self {
        case .s30: return "30 seconds"
        case .s60: return "1 minute"
        case .m5: return "5 minutes"
        }
    }
}
```

- [ ] **Step 2: Build + run the whole suite**

Run: `swift build && swift test`
Expected: `Build complete!`, all tests pass (DateParse 3, Format 4, Palette 3, UsageParser 3, KeychainReader 3, Reducer 5, UsageClient 3, UsageStore 3 = 27).

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeUsageCore/SettingsKeys.swift
git commit -m "Add settings keys and refresh-interval enum"
```

---

### Task 12: Ring gauge + color mapping (view)

**Files:**
- Create: `Sources/ClaudeUsage/ColorMap.swift`
- Create: `Sources/ClaudeUsage/RingView.swift`

**Interfaces:**
- Consumes: `RingColor`, `Palette`.
- Produces:
  - `func color(for ring: RingColor) -> Color` (green/orange/red).
  - `struct RingView: View` — `init(percent: Double, color: Color, lineWidth: CGFloat = 3, filled: Bool = true)`;
    draws a background track + a trimmed foreground arc from 12 o'clock. When `filled == false`
    (loading / needs-auth) draws only the dim track.

Views are verified by building and by the manual run in Task 17 (SwiftPM under CLT has no view unit tests).

- [ ] **Step 1: Write `ColorMap.swift`**

```swift
import SwiftUI
import ClaudeUsageCore

func color(for ring: RingColor) -> Color {
    switch ring {
    case .green: return .green
    case .amber: return .orange
    case .red: return .red
    }
}
```

- [ ] **Step 2: Write `RingView.swift`**

```swift
import SwiftUI

struct RingView: View {
    let percent: Double
    let color: Color
    var lineWidth: CGFloat = 3
    var filled: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            if filled {
                Circle()
                    .trim(from: 0, to: min(max(percent / 100, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeUsage/ColorMap.swift Sources/ClaudeUsage/RingView.swift
git commit -m "Add ring gauge view and RingColor->Color mapping"
```

---

### Task 13: Menu bar label (view)

**Files:**
- Create: `Sources/ClaudeUsage/MenuBarLabel.swift`

**Interfaces:**
- Consumes: `UsageState`, `Palette`, `Format`, `RefreshInterval`, `SettingsKeys`, `RingView`, `color(for:)`.
- Produces: `struct MenuBarLabel: View` — `init(state: UsageState, now: Date)`. Reads the four display
  toggles via `@AppStorage`. Renders (per toggles) a 14pt `RingView` + `NN%` + countdown + `7d NN%`.
  For `.needsAuth`/`.loading` shows a dim unfilled ring and no numbers; for `.stale` renders the last
  snapshot at reduced opacity.

- [ ] **Step 1: Write `MenuBarLabel.swift`**

```swift
import SwiftUI
import ClaudeUsageCore

struct MenuBarLabel: View {
    let state: UsageState
    let now: Date

    @AppStorage(SettingsKeys.showRing) private var showRing = true
    @AppStorage(SettingsKeys.showSessionPercent) private var showSession = true
    @AppStorage(SettingsKeys.showCountdown) private var showCountdown = true
    @AppStorage(SettingsKeys.showWeekly) private var showWeekly = true

    var body: some View {
        switch state {
        case .loading, .needsAuth:
            HStack(spacing: 4) {
                RingView(percent: 0, color: .secondary, filled: false)
                    .frame(width: 14, height: 14)
            }
        case .ok(let snap):
            content(snap, dim: false)
        case .stale(let snap, _):
            content(snap, dim: true)
        }
    }

    @ViewBuilder
    private func content(_ snap: UsageSnapshot, dim: Bool) -> some View {
        let ring = Palette.ring(percent: snap.session.percent, severity: snap.session.severity)
        HStack(spacing: 4) {
            if showRing {
                RingView(percent: snap.session.percent, color: color(for: ring))
                    .frame(width: 14, height: 14)
            }
            if showSession {
                Text("\(Int(snap.session.percent.rounded()))%")
            }
            if showCountdown {
                Text(Format.countdown(to: snap.session.resetsAt, now: now))
            }
            if showWeekly {
                Text("7d \(Int(snap.weekly.percent.rounded()))%")
            }
        }
        .opacity(dim ? 0.5 : 1)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeUsage/MenuBarLabel.swift
git commit -m "Add menu bar label view honoring display toggles"
```

---

### Task 14: Dropdown panel (view)

**Files:**
- Create: `Sources/ClaudeUsage/DropdownView.swift`

**Interfaces:**
- Consumes: `UsageStore`, `UsageState`, `UsageSnapshot`, `Format`, `RingView`, `SettingsView` (Task 16), `LoginItem` (Task 15 — the toggle is wired here but implemented in 15).
- Produces: `struct DropdownView: View` — `init(store: UsageStore)`. Shows the full breakdown for
  `.ok`/`.stale`, a sign-in message for `.needsAuth`, a spinner for `.loading`; plus
  `Refresh now`, `Settings…`, and `Quit`. Uses a 1-second `TimelineView` so the countdown ticks live.

- [ ] **Step 1: Write `DropdownView.swift`**

```swift
import SwiftUI
import ClaudeUsageCore

struct DropdownView: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                content(now: ctx.date)
            }
            Divider()
            Button("Refresh now") { Task { await store.refresh() } }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch store.state {
        case .loading:
            ProgressView("Loading…")
        case .needsAuth:
            Text("Sign in to Claude Code to see usage.")
                .foregroundStyle(.secondary)
        case .ok(let snap):
            breakdown(snap, now: now, footer: nil)
        case .stale(let snap, let since):
            breakdown(snap, now: now,
                      footer: "stale · couldn't reach Anthropic (\(Format.countdown(to: since, now: now)) ago)")
                .opacity(0.6)
        }
    }

    @ViewBuilder
    private func breakdown(_ snap: UsageSnapshot, now: Date, footer: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "5-hour session", percent: snap.session.percent,
                reset: "resets in \(Format.countdown(to: snap.session.resetsAt, now: now))")
            row(title: "7-day", percent: snap.weekly.percent,
                reset: resetDate(snap.weekly.resetsAt))
            if let c = snap.credits {
                Text(String(format: "Extra credits: %.\(c.decimalPlaces)f / %.0f %@",
                            c.used, c.limit, c.currency))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let footer {
                Text(footer).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(title: String, percent: Double, reset: String) -> some View {
        HStack(spacing: 8) {
            RingView(percent: percent,
                     color: color(for: Palette.ring(percent: percent, severity: "normal")))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading) {
                Text("\(title) — \(Int(percent.rounded()))%").font(.subheadline)
                Text(reset).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resetDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return "resets \(f.string(from: d))"
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeUsage/DropdownView.swift
git commit -m "Add dropdown breakdown panel with live countdown"
```

---

### Task 15: Launch-at-login wrapper

**Files:**
- Create: `Sources/ClaudeUsage/LoginItem.swift`

**Interfaces:**
- Produces: `enum LoginItem { static var isEnabled: Bool { get }; static func setEnabled(_ on: Bool) }`
  wrapping `SMAppService.mainApp`. `setEnabled` calls `register()`/`unregister()` and swallows/logs errors
  (registration only works from a real `.app` bundle — no-op-safe when run as a bare binary).

- [ ] **Step 1: Write `LoginItem.swift`**

```swift
import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeUsage/LoginItem.swift
git commit -m "Add SMAppService launch-at-login wrapper"
```

---

### Task 16: Settings window (view)

**Files:**
- Create: `Sources/ClaudeUsage/SettingsView.swift`

**Interfaces:**
- Consumes: `SettingsKeys`, `RefreshInterval`, `LoginItem`.
- Produces: `struct SettingsView: View` — `@AppStorage`-bound toggles for the four display elements,
  a refresh-interval `Picker`, and a `Launch at login` toggle bound through `LoginItem`. Changing the
  interval writes `SettingsKeys.refreshInterval`; the app observes this (Task 17) to restart polling.

- [ ] **Step 1: Write `SettingsView.swift`**

```swift
import SwiftUI
import ClaudeUsageCore

struct SettingsView: View {
    @AppStorage(SettingsKeys.showRing) private var showRing = true
    @AppStorage(SettingsKeys.showSessionPercent) private var showSession = true
    @AppStorage(SettingsKeys.showCountdown) private var showCountdown = true
    @AppStorage(SettingsKeys.showWeekly) private var showWeekly = true
    @AppStorage(SettingsKeys.refreshInterval) private var interval = RefreshInterval.s60.rawValue
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Ring gauge", isOn: $showRing)
                Toggle("5-hour %", isOn: $showSession)
                Toggle("Countdown to reset", isOn: $showCountdown)
                Toggle("Weekly %", isOn: $showWeekly)
            }
            Section("Behavior") {
                Picker("Refresh every", selection: $interval) {
                    ForEach(RefreshInterval.allCases, id: \.rawValue) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.setEnabled(on) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .padding()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeUsage/SettingsView.swift
git commit -m "Add settings window with display toggles and refresh interval"
```

---

### Task 17: Wire the app together

**Files:**
- Modify: `Sources/ClaudeUsage/ClaudeUsageApp.swift`

**Interfaces:**
- Consumes: everything above — `UsageStore`, `UsageClient`, `MenuBarLabel`, `DropdownView`, `SettingsView`,
  `SettingsKeys`, `RefreshInterval`, `LoginItem`.
- Produces: the final `@main` scene: a `MenuBarExtra` with `.menuBarExtraStyle(.window)` whose label is
  `MenuBarLabel` and whose content is `DropdownView`, plus a `Settings` scene. Registers default settings,
  starts polling at the stored interval, restarts polling when the interval changes, and enables
  launch-at-login on first run.

- [ ] **Step 1: Replace `ClaudeUsageApp.swift`**

```swift
import SwiftUI
import ClaudeUsageCore

@main
struct ClaudeUsageApp: App {
    @State private var store = UsageStore(fetcher: UsageClient())
    @AppStorage(SettingsKeys.refreshInterval) private var interval = RefreshInterval.s60.rawValue
    @AppStorage("didFirstRun") private var didFirstRun = false

    init() {
        SettingsKeys.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(store: store)
        } label: {
            MenuBarLabel(state: store.state, now: Date())
        }
        .menuBarExtraStyle(.window)
        .onChange(of: interval) { _, newValue in
            store.start(intervalSeconds: newValue)
        }

        Settings {
            SettingsView()
                .task {
                    if !didFirstRun {
                        LoginItem.setEnabled(true)
                        didFirstRun = true
                    }
                }
        }
        .onChange(of: store.state) { _, _ in }  // keep scene observing store
    }
}
```

- [ ] **Step 2: Start polling on launch**

The `MenuBarExtra` label doesn't get a lifecycle hook, so start the store from the dropdown's
`onAppear` won't cover the always-closed case. Instead start it in `init` via a `Task`. Update `init`:

```swift
    init() {
        SettingsKeys.registerDefaults()
        let stored = UserDefaults.standard.double(forKey: SettingsKeys.refreshInterval)
        let seconds = stored > 0 ? stored : RefreshInterval.s60.rawValue
        let s = store
        Task { @MainActor in s.start(intervalSeconds: seconds) }
    }
```

Note: `store` is a `@State` initialized inline, safe to reference in `init` after declaration.
If the compiler objects to capturing `store` in `init`, construct the store as a local `let`,
start it, and assign to `_store = State(initialValue: local)`.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Run the bare binary to smoke-test (menu bar item appears)**

Run: `swift run ClaudeUsage`
Expected: A menu bar item appears (a bare binary shows a Dock icon too — that's fine; the `.app`
bundle in Task 18 sets `LSUIElement` to hide it). Approve the one-time Keychain prompt with
**Always Allow**. The label should show real numbers within the refresh interval. Click it →
dropdown shows 5-hour + 7-day. `Ctrl-C` to quit.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeUsage/ClaudeUsageApp.swift
git commit -m "Wire MenuBarExtra scene: label, dropdown, settings, polling"
```

---

### Task 18: App bundle + launch at login (packaging)

**Files:**
- Create: `scripts/Info.plist`
- Create: `scripts/make-app.sh`

**Interfaces:**
- Consumes: the release binary from `swift build -c release`.
- Produces: `Claude Usage.app` in the repo root — an `LSUIElement` (no Dock icon) bundle with bundle id
  `com.przemek.ClaudeUsageMenuBar`, ad-hoc signed so `SMAppService` and Keychain access work for personal use.

- [ ] **Step 1: Write `scripts/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleIdentifier</key><string>com.przemek.ClaudeUsageMenuBar</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Write `scripts/make-app.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Claude Usage.app"
BIN_NAME="ClaudeUsage"

echo "Building release binary…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
echo "Install with:  cp -R \"$APP\" /Applications/  (then launch it once)"
```

- [ ] **Step 3: Make it executable and run it**

Run:
```bash
chmod +x scripts/make-app.sh && ./scripts/make-app.sh
```
Expected: ends with `Done: Claude Usage.app`; `codesign -dv "Claude Usage.app"` reports a signature.

- [ ] **Step 4: Launch the bundle and verify no Dock icon + live data**

Run: `open "Claude Usage.app"`
Expected: menu bar item appears with **no** Dock icon (LSUIElement). Real usage numbers show;
dropdown works; open Settings, toggle "Weekly %" off → the weekly figure disappears from the bar;
toggle "Launch at login" and confirm it appears in System Settings → General → Login Items.

- [ ] **Step 5: Add `.gitignore` entry for the built app and commit**

```bash
printf 'Claude Usage.app/\n.build/\n' >> .gitignore
git add scripts/Info.plist scripts/make-app.sh .gitignore
git commit -m "Add app bundling script and Info.plist (LSUIElement, ad-hoc sign)"
```

- [ ] **Step 6: Final full-suite check**

Run: `swift test`
Expected: all 27 tests pass.

---

## Self-Review

**Spec coverage:**
- Data source / endpoint / headers → Tasks 9 (client), 6 (parser). ✓
- Keychain token, `claudeAiOauth.accessToken` → Task 7. ✓
- Never manages auth, re-reads each poll → Task 9 (`tokenProvider` default reads Keychain; called every `fetch`). ✓
- One-time Keychain prompt → surfaced in Task 17 Step 4. ✓
- SwiftUI `MenuBarExtra`, macOS 14, no deps → Tasks 1, 17; Global Constraints. ✓
- Ring + 5h% + countdown + weekly%, each toggleable → Tasks 12, 13, 16. ✓
- Ring color by severity + fallback thresholds → Task 5. ✓
- Dropdown: 5h / 7-day / credits / last-updated+refresh / settings / quit → Task 14. ✓
- Settings: 4 toggles + interval + launch-at-login → Task 16. ✓
- Launch at login via SMAppService, on by first run → Tasks 15, 17. ✓
- States: loading / ok / stale / needsAuth → Tasks 8 (reducer), 13, 14. ✓
- Poll every interval + refresh on dropdown open → Task 10 (loop) + Task 14 (`Refresh now`; `TimelineView` ticks countdown). Note: refresh-on-open is covered by the periodic loop + manual button; an explicit fetch-on-open is optional polish, not separately tasked.
- Distribution: SwiftPM build + bundle script, ad-hoc sign, LSUIElement → Task 18. ✓
- Testing plan (parse, decode, state mapping, severity, countdown) → Tasks 2,3,5,6,7,8,9,10. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `UsageWindow`, `UsageSnapshot`, `UsageState`, `UsageError`, `RingColor`, `Credits`
defined in Task 4 and used consistently. `Palette.ring`, `Format.countdown`, `DateParse.iso`,
`UsageParser.snapshot`, `KeychainReader.token(fromJSON:)`/`readToken`, `Reducer.map`, `UsageFetching.fetch`,
`UsageClient.init`, `UsageStore.refresh/start/stop`, `SettingsKeys.*`, `RefreshInterval` — signatures match
across producing and consuming tasks. ✓

One known risk carried into execution: Task 17 Step 2's `store` capture in `init` may need the
`State(initialValue:)` fallback spelled out in the step; the fallback is documented inline.

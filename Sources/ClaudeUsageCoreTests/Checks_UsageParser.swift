import Foundation
import ClaudeUsageCore

func usageParserChecks() {
    t.group("UsageParser")
    let now = Date(timeIntervalSince1970: 1000)
    func load(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            t.expect(false, "fixture \(name).json not found"); return Data()
        }
        return data
    }
    if let snap = try? UsageParser.snapshot(from: load("usage_full"), now: now) {
        t.equal(snap.session.percent, 38)
        t.equal(snap.session.severity, "normal")
        t.equal(snap.weeklyAll.percent, 19)
        t.equal(snap.weeklyAll.severity, "normal")
        t.equal(snap.modelWeekly.count, 1)
        if let model = snap.modelWeekly.first {
            t.equal(model.displayName, "Fable")
            t.expect(model.modelID == nil, "Fable fixture should not have a model ID")
            t.equal(model.percent, 22)
            t.equal(model.severity, "warning")
            t.notNil(model.resetsAt)
        }
        t.equal(snap.credits?.used ?? -1, 12.34)
        t.equal(snap.credits?.limit ?? -1, 50)
        t.equal(snap.credits?.currency ?? "", "CAD")
        t.equal(snap.fetchedAt, now)
    } else {
        t.expect(false, "full fixture should parse")
    }
    if let snap = try? UsageParser.snapshot(from: load("usage_no_limits"), now: now) {
        t.equal(snap.session.percent, 50)
        t.equal(snap.weeklyAll.percent, 25)
        t.expect(snap.modelWeekly.isEmpty, "fallback fixture should have no model usage")
        t.expect(snap.credits == nil, "credits should be nil when extra_usage disabled")
    } else {
        t.expect(false, "no_limits fixture should parse")
    }

    let scopedJSON = #"{"five_hour":{"utilization":5,"resets_at":"2026-07-07T19:40:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-07-11T08:00:00Z"},"limits":[{"kind":"weekly_all","percent":20,"severity":"normal","resets_at":"invalid"},{"kind":"weekly_scoped","group":"weekly","percent":41,"severity":"warning","scope":{"model":{"id":"opus","display_name":" Opus "}}},{"kind":"weekly_scoped","group":"weekly","percent":99,"scope":{"model":{"id":"opus","display_name":"Duplicate Opus"}}},{"kind":"weekly_scoped","group":"weekly","percent":55,"scope":{"model":{"display_name":"Sonnet"}},"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":60,"scope":{"model":{"display_name":"sonnet"}}},{"kind":"weekly_scoped","group":"weekly","percent":70,"scope":{"model":{"display_name":"   "}}}]}"#
    if let snap = try? UsageParser.snapshot(from: Data(scopedJSON.utf8), now: now) {
        t.equal(snap.weeklyAll.percent, 10)
        t.equal(snap.modelWeekly.count, 2)
        if snap.modelWeekly.count == 2 {
            t.equal(snap.modelWeekly[0].displayName, "Opus")
            t.equal(snap.modelWeekly[0].modelID, "opus")
            t.equal(snap.modelWeekly[0].percent, 41)
            t.expect(snap.modelWeekly[0].resetsAt == nil, "missing model reset should be retained")
            t.equal(snap.modelWeekly[1].displayName, "Sonnet")
            t.equal(snap.modelWeekly[1].percent, 55)
        }
    } else {
        t.expect(false, "scoped model fixture should parse")
    }

    let scopedOnlyJSON = #"{"limits":[{"kind":"session","percent":1,"resets_at":"2026-07-07T19:40:00Z"},{"kind":"weekly_scoped","percent":2,"scope":{"model":{"display_name":"Fable"}}}]}"#
    t.throwsError("scoped-only weekly usage must not become all-model usage") {
        _ = try UsageParser.snapshot(from: Data(scopedOnlyJSON.utf8), now: now)
    }
    t.throwsError("empty object should throw") {
        _ = try UsageParser.snapshot(from: Data("{}".utf8), now: now)
    }

    let extremeJSON = #"{"five_hour":{"utilization":1e100,"resets_at":"2026-07-07T19:40:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-07-11T08:00:00Z"}}"#
    t.throwsError("unbounded percentage should be rejected") {
        _ = try UsageParser.snapshot(from: Data(extremeJSON.utf8), now: now)
    }

    let badCreditsJSON = #"{"five_hour":{"utilization":5,"resets_at":"2026-07-07T19:40:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-07-11T08:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":100,"monthly_limit":500,"decimal_places":1000}}"#
    if let snap = try? UsageParser.snapshot(from: Data(badCreditsJSON.utf8), now: now) {
        t.expect(snap.credits == nil, "invalid credit precision should omit credits")
    } else {
        t.expect(false, "invalid optional credits must not reject usage windows")
    }
}

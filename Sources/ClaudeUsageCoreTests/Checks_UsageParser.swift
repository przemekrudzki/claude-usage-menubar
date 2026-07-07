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
        t.equal(snap.weekly.percent, 22)
        t.equal(snap.weekly.severity, "warning")
        t.equal(snap.credits?.used ?? -1, 12.34)
        t.equal(snap.credits?.limit ?? -1, 50)
        t.equal(snap.credits?.currency ?? "", "CAD")
        t.equal(snap.fetchedAt, now)
    } else {
        t.expect(false, "full fixture should parse")
    }
    if let snap = try? UsageParser.snapshot(from: load("usage_no_limits"), now: now) {
        t.equal(snap.session.percent, 50)
        t.equal(snap.weekly.percent, 25)
        t.expect(snap.credits == nil, "credits should be nil when extra_usage disabled")
    } else {
        t.expect(false, "no_limits fixture should parse")
    }
    t.throwsError("empty object should throw") {
        _ = try UsageParser.snapshot(from: Data("{}".utf8), now: now)
    }
}

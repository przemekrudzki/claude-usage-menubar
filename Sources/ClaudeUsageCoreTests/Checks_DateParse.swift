import Foundation
import ClaudeUsageCore

func dateParseChecks() {
    t.group("DateParse")
    if let d = t.notNil(DateParse.iso("2026-07-09T19:40:00.384593+00:00")) {
        t.close(d.timeIntervalSince1970, 1783626000, 1)
    }
    t.notNil(DateParse.iso("2026-07-11T08:00:00+00:00"))
    t.expect(DateParse.iso("not-a-date") == nil, "garbage should return nil")
}

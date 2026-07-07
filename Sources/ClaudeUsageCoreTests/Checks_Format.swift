import Foundation
import ClaudeUsageCore

func formatChecks() {
    t.group("Format")
    func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }
    t.equal(Format.countdown(to: at(2*3600 + 13*60), now: at(0)), "2h 13m")
    t.equal(Format.countdown(to: at(13*60), now: at(0)), "13m")
    t.equal(Format.countdown(to: at(30), now: at(0)), "<1m")
    t.equal(Format.countdown(to: at(0), now: at(60)), "now")
}

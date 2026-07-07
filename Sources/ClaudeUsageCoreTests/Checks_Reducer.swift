import Foundation
import ClaudeUsageCore

func reducerChecks() {
    t.group("Reducer")
    let now = Date(timeIntervalSince1970: 5000)
    func snap(_ p: Double) -> UsageSnapshot {
        let w = UsageWindow(percent: p, resetsAt: Date(timeIntervalSince1970: 9999), severity: "normal")
        return UsageSnapshot(session: w, weekly: w, credits: nil, fetchedAt: now)
    }
    t.equal(Reducer.map(.success(snap(10)), previous: .loading, now: now), .ok(snap(10)))
    t.equal(Reducer.map(.failure(.unauthorized), previous: .ok(snap(10)), now: now), .needsAuth)
    t.equal(Reducer.map(.failure(.noToken), previous: .loading, now: now), .needsAuth)
    t.equal(Reducer.map(.failure(.network("x")), previous: .ok(snap(10)), now: now), .stale(snap(10), since: now))
    let since = Date(timeIntervalSince1970: 100)
    t.equal(Reducer.map(.failure(.network("x")), previous: .stale(snap(10), since: since), now: now), .stale(snap(10), since: since))
    t.equal(Reducer.map(.failure(.network("x")), previous: .loading, now: now), .loading)
}

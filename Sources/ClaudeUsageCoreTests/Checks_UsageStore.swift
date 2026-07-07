import Foundation
import ClaudeUsageCore

struct StubFetcher: UsageFetching {
    let result: Result<UsageSnapshot, UsageError>
    func fetch() async -> Result<UsageSnapshot, UsageError> { result }
}

final class SeqFetcher: UsageFetching, @unchecked Sendable {
    private var results: [Result<UsageSnapshot, UsageError>]
    init(_ results: [Result<UsageSnapshot, UsageError>]) { self.results = results }
    func fetch() async -> Result<UsageSnapshot, UsageError> {
        results.isEmpty ? .failure(.network("x")) : results.removeFirst()
    }
}

@MainActor
func usageStoreChecks() async {
    t.group("UsageStore")
    let now = Date(timeIntervalSince1970: 42)
    func snap(_ p: Double) -> UsageSnapshot {
        let w = UsageWindow(percent: p, resetsAt: Date(timeIntervalSince1970: 9999), severity: "normal")
        return UsageSnapshot(session: w, weekly: w, credits: nil, fetchedAt: now)
    }
    let s1 = UsageStore(fetcher: StubFetcher(result: .success(snap(33))), now: { now })
    await s1.refresh()
    t.equal(s1.state, .ok(snap(33)))

    let s2 = UsageStore(fetcher: StubFetcher(result: .failure(.unauthorized)), now: { now })
    await s2.refresh()
    t.equal(s2.state, .needsAuth)

    let s3 = UsageStore(fetcher: StubFetcher(result: .failure(.network("x"))), now: { now })
    t.equal(s3.state, .loading)

    let seq = UsageStore(fetcher: SeqFetcher([.success(snap(50)), .failure(.network("x"))]), now: { now })
    await seq.refresh()
    t.equal(seq.state, .ok(snap(50)))
    await seq.refresh()
    t.equal(seq.state, .stale(snap(50), since: now))
}

import Foundation
import ClaudeUsageCore

struct StubFetcher: UsageFetching {
    let result: Result<UsageSnapshot, UsageError>
    func fetch() async -> Result<UsageSnapshot, UsageError> { result }
}

actor SeqFetcher: UsageFetching {
    private var results: [Result<UsageSnapshot, UsageError>]
    private(set) var resultsConsumed = 0
    init(_ results: [Result<UsageSnapshot, UsageError>]) { self.results = results }
    func fetch() async -> Result<UsageSnapshot, UsageError> {
        resultsConsumed += 1
        return results.isEmpty ? .failure(.network("x")) : results.removeFirst()
    }
}

actor BlockingFetcher: UsageFetching {
    private var continuation: CheckedContinuation<Result<UsageSnapshot, UsageError>, Never>?
    private(set) var calls = 0

    func fetch() async -> Result<UsageSnapshot, UsageError> {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ result: Result<UsageSnapshot, UsageError>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

final class MutableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func get() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@MainActor
func usageStoreChecks() async {
    t.group("UsageStore")
    let now = Date(timeIntervalSince1970: 42)
    func snap(_ p: Double) -> UsageSnapshot {
        let w = UsageWindow(percent: p, resetsAt: Date(timeIntervalSince1970: 9999), severity: "normal")
        return UsageSnapshot(session: w, weeklyAll: w, credits: nil, fetchedAt: now)
    }
    let s1 = UsageStore(fetcher: StubFetcher(result: .success(snap(33))), now: { now })
    await s1.refresh()
    t.equal(s1.state, .ok(snap(33)))

    let s2 = UsageStore(fetcher: StubFetcher(result: .failure(.unauthorized)), now: { now })
    await s2.refresh()
    t.equal(s2.state, .needsAuth)

    let s3 = UsageStore(fetcher: StubFetcher(result: .failure(.network("x"))), now: { now })
    await s3.refresh()
    t.equal(s3.state, .unavailable(.network("x")))

    let seq = UsageStore(fetcher: SeqFetcher([.success(snap(50)), .failure(.network("x"))]), now: { now })
    await seq.refresh()
    t.equal(seq.state, .ok(snap(50)))
    await seq.refresh()
    t.equal(seq.state, .stale(snap(50), since: now))

    let blocker = BlockingFetcher()
    let singleFlight = UsageStore(fetcher: blocker, now: { now })
    let first = Task { await singleFlight.refresh(trigger: .startup) }
    while await blocker.calls == 0 { await Task.yield() }
    let second = Task { await singleFlight.refresh(trigger: .manual) }
    await Task.yield()
    t.equal(await blocker.calls, 1)
    await blocker.release(.success(snap(75)))
    await first.value
    await second.value
    t.equal(singleFlight.state, .ok(snap(75)))

    let waiterFetcher = BlockingFetcher()
    let waiterStore = UsageStore(fetcher: waiterFetcher, now: { now })
    let owner = Task { await waiterStore.refresh(trigger: .poll) }
    while await waiterFetcher.calls == 0 { await Task.yield() }
    let cancelledWaiter = Task { await waiterStore.refresh(trigger: .menuOpen) }
    await Task.yield()
    cancelledWaiter.cancel()
    await cancelledWaiter.value
    t.equal(await waiterFetcher.calls, 1)
    await waiterFetcher.release(.success(snap(76)))
    await owner.value

    let reconnectFetcher = BlockingFetcher()
    let reconnectStore = UsageStore(fetcher: reconnectFetcher, now: { now }, jitter: { _ in 0 })
    let offlineRequest = Task { await reconnectStore.refresh(trigger: .poll) }
    while await reconnectFetcher.calls == 0 { await Task.yield() }
    let reconnectRequest = Task { await reconnectStore.refresh(trigger: .connectivity) }
    await reconnectFetcher.release(.failure(.network("offline")))
    await offlineRequest.value
    await reconnectRequest.value
    while await reconnectFetcher.calls < 2 { await Task.yield() }
    await reconnectFetcher.release(.success(snap(80)))
    while reconnectStore.state != .ok(snap(80)) { await Task.yield() }
    t.equal(reconnectStore.state, .ok(snap(80)))

    let cancelledFetcher = BlockingFetcher()
    let cancelledStore = UsageStore(fetcher: cancelledFetcher, now: { now })
    let cancelledRefresh = Task { await cancelledStore.refresh() }
    while await cancelledFetcher.calls == 0 { await Task.yield() }
    cancelledStore.stop()
    await cancelledRefresh.value
    await cancelledFetcher.release(.failure(.network("late")))
    t.equal(cancelledStore.state, .loading)
    t.expect(cancelledStore.lastError == nil, "cancelled obsolete request must not commit")

    let clock = MutableNow(now)
    let gateFetcher = SeqFetcher([
        .failure(.rateLimited(retryAfter: 300)),
        .success(snap(90)),
    ])
    let gated = UsageStore(fetcher: gateFetcher, now: { clock.get() }, jitter: { _ in 0 })
    await gated.refresh()
    t.equal(await gateFetcher.resultsConsumed, 1)
    await gated.refresh(trigger: .wake)
    await gated.refresh(trigger: .connectivity)
    t.equal(await gateFetcher.resultsConsumed, 1)
    clock.advance(300)
    await gated.refresh()
    t.equal(await gateFetcher.resultsConsumed, 2)
    t.equal(gated.state, .ok(snap(90)))

    // A server asking for an hour must not blank the app for an hour: the first probe
    // is 2 minutes in, and the ceiling only doubles from there.
    let hugeRetryFetcher = SeqFetcher([
        .failure(.rateLimited(retryAfter: 1e300)),
        .failure(.rateLimited(retryAfter: 3600)),
        .failure(.rateLimited(retryAfter: 3600)),
    ])
    let hugeClock = MutableNow(now)
    let hugeRetry = UsageStore(fetcher: hugeRetryFetcher, now: { hugeClock.get() },
                               jitter: { _ in 0 })
    await hugeRetry.refresh()
    t.equal(hugeRetry.backoffSeconds, 120)
    t.equal(hugeRetry.nextRetryAt, now.addingTimeInterval(120))
    hugeClock.advance(120)
    await hugeRetry.refresh()
    t.equal(hugeRetry.backoffSeconds, 240)
    hugeClock.advance(240)
    await hugeRetry.refresh()
    t.equal(hugeRetry.backoffSeconds, 480)

    // `Retry-After: 0` used to mean "retry every poll tick, forever"; it now has a floor.
    let zeroRetry = UsageStore(fetcher: StubFetcher(result: .failure(.rateLimited(retryAfter: 0))),
                               now: { now }, jitter: { _ in 0 })
    await zeroRetry.refresh()
    t.equal(zeroRetry.backoffSeconds, 30)

    // An expired token is spotted locally, so re-checking costs nothing: no backoff,
    // and the very next poll picks up whatever Claude Code has refreshed.
    let expiredFetcher = SeqFetcher([.failure(.tokenExpired), .success(snap(60))])
    let expired = UsageStore(fetcher: expiredFetcher, now: { now }, jitter: { _ in 0 })
    await expired.refresh()
    t.equal(expired.state, .unavailable(.tokenExpired))
    t.equal(expired.backoffSeconds, 0)
    t.expect(expired.nextRetryAt == nil, "expired token must not gate the next poll")
    await expired.refresh(trigger: .poll)
    t.equal(expired.state, .ok(snap(60)))

    // A token the server rejects is a different story — re-sending it every minute is
    // what earns the hour-long lockout, so it backs off 2m, 4m, 8m…
    let rejectedClock = MutableNow(now)
    let rejected = UsageStore(fetcher: StubFetcher(result: .failure(.unauthorized)),
                              now: { rejectedClock.get() }, jitter: { _ in 0 })
    await rejected.refresh()
    t.equal(rejected.backoffSeconds, 120)
    t.equal(rejected.state, .needsAuth)
    rejectedClock.advance(120)
    await rejected.refresh(trigger: .poll)
    t.equal(rejected.backoffSeconds, 240)

    // …but the user can always force one through.
    let manualFetcher = SeqFetcher([.failure(.rateLimited(retryAfter: 3600)), .success(snap(70))])
    let manual = UsageStore(fetcher: manualFetcher, now: { now }, jitter: { _ in 0 })
    await manual.refresh(trigger: .poll)
    t.equal(await manualFetcher.resultsConsumed, 1)
    await manual.refresh(trigger: .menuOpen)
    t.equal(await manualFetcher.resultsConsumed, 1)
    await manual.refresh(trigger: .manual)
    t.equal(await manualFetcher.resultsConsumed, 2)
    t.equal(manual.state, .ok(snap(70)))

    let watchdogFetcher = BlockingFetcher()
    let watchdogStore = UsageStore(fetcher: watchdogFetcher, now: { now },
                                   jitter: { _ in 0 }, requestTimeoutSeconds: 0.02)
    let watchdogRefresh = Task { await watchdogStore.refresh() }
    while await watchdogFetcher.calls == 0 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
    await watchdogRefresh.value
    t.equal(watchdogStore.state, .unavailable(.requestTimeout))
    t.expect(!watchdogStore.isRefreshing, "watchdog should release the single-flight slot")
    await watchdogFetcher.release(.failure(.cancelled))

    let intervalFetcher = SeqFetcher([.success(snap(10)), .success(snap(20))])
    let normalizedPoll = UsageStore(fetcher: intervalFetcher, now: { now })
    normalizedPoll.start(intervalSeconds: 0)
    try? await Task.sleep(for: .milliseconds(50))
    normalizedPoll.stop()
    t.equal(await intervalFetcher.resultsConsumed, 1)
}

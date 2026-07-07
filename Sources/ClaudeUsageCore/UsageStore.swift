import Foundation
import Observation

@MainActor
@Observable
public final class UsageStore {
    public private(set) var state: UsageState = .loading

    private let fetcher: UsageFetching
    private let now: @Sendable () -> Date
    private var pollTask: Task<Void, Never>?

    /// Extra delay (seconds) requested by the last fetch — set when the server
    /// rate-limits us (HTTP 429). Clamped to [60, 600]. 0 when not backing off.
    public private(set) var backoffSeconds: Double = 0

    public init(fetcher: UsageFetching, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.now = now
    }

    public func refresh() async {
        let result = await fetcher.fetch()
        if case .failure(.rateLimited(let retryAfter)) = result {
            backoffSeconds = min(max(retryAfter ?? 120, 60), 600)
        } else {
            backoffSeconds = 0
        }
        state = Reducer.map(result, previous: state, now: now())
    }

    public func start(intervalSeconds: Double) {
        stop()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let delay = max(intervalSeconds, self.backoffSeconds)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

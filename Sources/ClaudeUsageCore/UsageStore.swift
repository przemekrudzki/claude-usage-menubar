import Foundation
import Observation

@MainActor
@Observable
public final class UsageStore {
    public private(set) var state: UsageState = .loading

    private let fetcher: UsageFetching
    private let now: @Sendable () -> Date
    private var pollTask: Task<Void, Never>?

    public init(fetcher: UsageFetching, now: @escaping @Sendable () -> Date = { Date() }) {
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

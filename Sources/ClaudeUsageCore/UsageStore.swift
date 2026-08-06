import Foundation
import Observation
import OSLog

public enum RefreshTrigger: String, Sendable {
    case startup, poll, menuOpen, manual, connectivity, wake
}

@MainActor
@Observable
public final class UsageStore {
    public private(set) var state: UsageState = .loading
    public private(set) var isRefreshing = false
    public private(set) var lastError: UsageError?
    public private(set) var lastAttemptAt: Date?
    public private(set) var nextRetryAt: Date?

    private let fetcher: UsageFetching
    private let now: @Sendable () -> Date
    private let jitter: @Sendable (ClosedRange<Double>) -> Double
    private let cache: (any UsageSnapshotCaching)?
    private let requestTimeoutSeconds: Double
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    private var waiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var pendingConnectivityRefresh = false
    private var consecutiveTransientFailures = 0
    private var consecutiveRateLimits = 0
    private var consecutiveAuthFailures = 0
    private let logger = Logger(subsystem: "com.przemek.ClaudeUsageMenuBar", category: "usage-store")

    /// First retry after a 429, regardless of how long the server asks us to wait.
    static let rateLimitProbeBase: Double = 120
    /// Floor for rate-limit backoff — a `Retry-After: 0` must not become a spin loop.
    static let minimumRateLimitBackoff: Double = 30
    /// Poll cadence while waiting for Claude Code to refresh an expired token.
    static let expiredTokenPollSeconds: Double = 30

    /// Current delay requested by retry policy. 0 when not backing off.
    public private(set) var backoffSeconds: Double = 0

    public init(fetcher: UsageFetching,
                now: @escaping @Sendable () -> Date = { Date() },
                jitter: @escaping @Sendable (ClosedRange<Double>) -> Double = {
                    Double.random(in: $0)
                },
                cache: (any UsageSnapshotCaching)? = nil,
                maximumCacheAge: TimeInterval = 24 * 60 * 60,
                requestTimeoutSeconds: Double = 35) {
        self.fetcher = fetcher
        self.now = now
        self.jitter = jitter
        self.cache = cache
        self.requestTimeoutSeconds = requestTimeoutSeconds.isFinite
            ? min(max(requestTimeoutSeconds, 0.01), 300)
            : 35
        let cacheAge = maximumCacheAge.isFinite && maximumCacheAge >= 0
            ? maximumCacheAge
            : 24 * 60 * 60
        if let snapshot = try? cache?.load(),
           (-300...cacheAge).contains(now().timeIntervalSince(snapshot.fetchedAt)) {
            state = .stale(snapshot, since: snapshot.fetchedAt)
        }
    }

    public func refresh(trigger: RefreshTrigger = .manual) async {
        guard !Task.isCancelled else { return }
        if let requestID = activeRequestID {
            if trigger == .connectivity { pendingConnectivityRefresh = true }
            await waitForCompletion(of: requestID)
            return
        }

        let startedAt = now()
        if let nextRetryAt, nextRetryAt > startedAt {
            // A manual refresh is one deliberate request and can't loop, so it always
            // wins over the backoff — being told to wait 48 minutes with no way to ask
            // again is worse than the request it saves. Automatic triggers stay gated,
            // except reconnecting after a connectivity failure.
            let overrides = trigger == .manual
                || (trigger == .connectivity && Self.isConnectivityFailure(lastError))
            guard overrides else { return }
            self.nextRetryAt = nil
            backoffSeconds = 0
        }

        let requestID = UUID()
        activeRequestID = requestID
        isRefreshing = true
        lastAttemptAt = startedAt
        let fetcher = self.fetcher
        logger.debug("Refresh started; trigger=\(trigger.rawValue, privacy: .public)")

        let task = Task { [weak self] in
            let result = await fetcher.fetch()
            guard let self else { return }
            self.complete(result, requestID: requestID, startedAt: startedAt)
        }
        refreshTask = task
        watchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(self?.requestTimeoutSeconds ?? 35))
            } catch {
                return
            }
            self?.requestTimedOut(requestID: requestID)
        }
        await waitForCompletion(of: requestID)
    }

    public func start(intervalSeconds: Double) {
        pollTask?.cancel()
        let interval = Self.normalizedInterval(intervalSeconds)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(trigger: .poll)
                guard !Task.isCancelled else { return }
                let retryDelay = self.nextRetryAt.map {
                    max(0, $0.timeIntervalSince(self.now()))
                } ?? 0
                // Re-checking an expired token is a local Keychain read, not a request,
                // so poll for the refreshed one faster than the user's interval — the
                // app should come back to life shortly after they run Claude Code.
                let delay = self.lastError == .tokenExpired
                    ? min(interval, Self.expiredTokenPollSeconds)
                    : max(interval, retryDelay)
                guard delay.isFinite else { return }
                do {
                    try await Task.sleep(for: .seconds(min(max(delay, 1), 3600)))
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        followUpTask?.cancel()
        followUpTask = nil
        if let activeRequestID { resolveWaiters(for: activeRequestID) }
        activeRequestID = nil
        pendingConnectivityRefresh = false
        isRefreshing = false
    }

    private func complete(_ result: Result<UsageSnapshot, UsageError>,
                          requestID: UUID, startedAt: Date) {
        guard activeRequestID == requestID else { return }
        defer {
            watchdogTask?.cancel()
            watchdogTask = nil
            refreshTask = nil
            activeRequestID = nil
            isRefreshing = false
            resolveWaiters(for: requestID)
        }

        if case .failure(.cancelled) = result { return }
        let completedAt = now()
        updateRetryPolicy(for: result, at: completedAt)
        if case .failure(let error) = result {
            lastError = error
            logger.error("Refresh failed after \(completedAt.timeIntervalSince(startedAt), privacy: .public)s: \(String(describing: error), privacy: .public)")
        } else {
            lastError = nil
            logger.debug("Refresh completed in \(completedAt.timeIntervalSince(startedAt), privacy: .public)s")
        }
        state = Reducer.map(result, previous: state, now: completedAt)
        if case .success(let snapshot) = result {
            do {
                try cache?.save(snapshot)
            } catch {
                logger.error("Could not persist usage snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
        schedulePendingRefresh(after: result)
    }

    private func requestTimedOut(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        let task = refreshTask
        activeRequestID = nil
        refreshTask = nil
        watchdogTask = nil
        isRefreshing = false
        task?.cancel()

        let result: Result<UsageSnapshot, UsageError> = .failure(.requestTimeout)
        let completedAt = now()
        lastError = .requestTimeout
        updateRetryPolicy(for: result, at: completedAt)
        state = Reducer.map(result, previous: state, now: completedAt)
        logger.error("Refresh exceeded the request deadline")
        schedulePendingRefresh(after: result)
        resolveWaiters(for: requestID)
    }

    private func schedulePendingRefresh(after result: Result<UsageSnapshot, UsageError>) {
        guard pendingConnectivityRefresh else { return }
        pendingConnectivityRefresh = false
        guard case .failure(let error) = result, Self.isConnectivityFailure(error) else {
            return
        }
        nextRetryAt = nil
        backoffSeconds = 0
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refresh(trigger: .connectivity)
        }
    }

    private func waitForCompletion(of requestID: UUID) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, activeRequestID == requestID else {
                    continuation.resume()
                    return
                }
                waiters[requestID, default: [:]][waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID, for: requestID)
            }
        }
    }

    private func resolveWaiters(for requestID: UUID) {
        guard let continuations = waiters.removeValue(forKey: requestID) else { return }
        continuations.values.forEach { $0.resume() }
    }

    private func cancelWaiter(_ waiterID: UUID, for requestID: UUID) {
        guard let continuation = waiters[requestID]?.removeValue(forKey: waiterID) else { return }
        if waiters[requestID]?.isEmpty == true { waiters.removeValue(forKey: requestID) }
        continuation.resume()
    }

    private static func isConnectivityFailure(_ error: UsageError?) -> Bool {
        switch error {
        case .network, .transport, .requestTimeout:
            return true
        default:
            return false
        }
    }

    /// Per-family attempt counters, so rate-limit and auth backoff each escalate on
    /// their own history rather than on one shared "something went wrong" tally.
    private func trackConsecutiveFailures(for result: Result<UsageSnapshot, UsageError>) {
        guard case .failure(let error) = result else {
            consecutiveRateLimits = 0
            consecutiveAuthFailures = 0
            return
        }
        switch error {
        case .cancelled:
            break  // an abandoned attempt is evidence of nothing
        case .rateLimited:
            consecutiveRateLimits += 1
            consecutiveAuthFailures = 0
        case .unauthorized, .forbidden:
            consecutiveAuthFailures += 1
            consecutiveRateLimits = 0
        default:
            consecutiveRateLimits = 0
            consecutiveAuthFailures = 0
        }
    }

    private func updateRetryPolicy(for result: Result<UsageSnapshot, UsageError>, at date: Date) {
        trackConsecutiveFailures(for: result)

        switch result {
        case .success:
            consecutiveTransientFailures = 0
            backoffSeconds = 0
            nextRetryAt = nil
        case .failure(.rateLimited(let retryAfter)):
            consecutiveTransientFailures += 1
            let requested = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                ?? Self.rateLimitProbeBase
            // Honour Retry-After, but probe well before a long server-suggested wait.
            // The hour-long lockout the API hands out after repeated auth failures
            // clears as soon as a fresh token is in play, and waiting it out leaves
            // the app showing day-old numbers. Ceiling doubles per consecutive 429:
            // 2m, 4m, 8m, 16m, 32m, then the server's figure.
            let exponent = min(max(consecutiveRateLimits - 1, 0), 5)
            let ceiling = min(Self.rateLimitProbeBase * pow(2, Double(exponent)), 3600)
            let chosen = min(requested, ceiling)
            backoffSeconds = min(max(chosen, Self.minimumRateLimitBackoff), 3600)
            nextRetryAt = date.addingTimeInterval(backoffSeconds)
        case .failure(.network), .failure(.transport), .failure(.credentialTimeout),
             .failure(.requestTimeout):
            consecutiveTransientFailures += 1
            let exponent = min(consecutiveTransientFailures - 1, 5)
            let base = min(15 * pow(2, Double(exponent)), 300)
            let jitterValue = jitter(0...(base * 0.2))
            backoffSeconds = base + (jitterValue.isFinite ? min(max(jitterValue, 0), base * 0.2) : 0)
            nextRetryAt = date.addingTimeInterval(backoffSeconds)
        case .failure(.httpStatus(let status)) where status == 408 || status >= 500:
            consecutiveTransientFailures += 1
            let exponent = min(consecutiveTransientFailures - 1, 5)
            let base = min(15 * pow(2, Double(exponent)), 300)
            let jitterValue = jitter(0...(base * 0.2))
            backoffSeconds = base + (jitterValue.isFinite ? min(max(jitterValue, 0), base * 0.2) : 0)
            nextRetryAt = date.addingTimeInterval(backoffSeconds)
        case .failure(.decoding), .failure(.responseTooLarge):
            consecutiveTransientFailures += 1
            backoffSeconds = 300
            nextRetryAt = date.addingTimeInterval(backoffSeconds)
        case .failure(.cancelled):
            break
        case .failure(.unauthorized), .failure(.forbidden):
            // A token the server actively rejects must not be re-sent on every poll
            // tick: that is what earns the hour-long 429 lockout. Back off hard and
            // let the local expiry check (or a manual refresh) drive recovery.
            consecutiveTransientFailures = 0
            let exponent = min(max(consecutiveAuthFailures - 1, 0), 4)
            backoffSeconds = min(120 * pow(2, Double(exponent)), 1800)
            nextRetryAt = date.addingTimeInterval(backoffSeconds)
        case .failure(.tokenExpired):
            // Detected without a request, so re-checking is free — no backoff. The
            // next poll picks the token up the moment Claude Code refreshes it.
            consecutiveTransientFailures = 0
            backoffSeconds = 0
            nextRetryAt = nil
        case .failure(.noToken), .failure(.credentialAccess), .failure(.httpStatus):
            consecutiveTransientFailures = 0
            backoffSeconds = 0
            nextRetryAt = nil
        }
    }

    private static func normalizedInterval(_ value: Double) -> Double {
        guard value.isFinite, RefreshInterval(rawValue: value) != nil else {
            return RefreshInterval.s60.rawValue
        }
        return value
    }
}

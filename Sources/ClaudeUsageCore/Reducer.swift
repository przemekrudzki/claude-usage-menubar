import Foundation

public enum Reducer {
    public static func map(_ result: Result<UsageSnapshot, UsageError>,
                           previous: UsageState, now: Date) -> UsageState {
        switch result {
        case .success(let snap):
            return .ok(snap)
        case .failure(let err):
            switch err {
            case .cancelled:
                return previous
            case .noToken, .unauthorized, .forbidden:
                if let stale = staleState(from: previous, now: now) { return stale }
                return .needsAuth
            case .credentialAccess, .credentialTimeout, .requestTimeout,
                 .network, .transport, .httpStatus,
                 .decoding, .rateLimited, .responseTooLarge:
                if let stale = staleState(from: previous, now: now) { return stale }
                return .unavailable(err)
            }
        }
    }

    private static func staleState(from state: UsageState, now: Date) -> UsageState? {
        switch state {
        case .ok(let snap):
            return .stale(snap, since: now)
        case .stale(let snap, let since):
            return .stale(snap, since: since)
        case .loading, .needsAuth, .unavailable:
            return nil
        }
    }
}

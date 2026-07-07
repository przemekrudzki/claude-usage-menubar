import Foundation

public enum Reducer {
    public static func map(_ result: Result<UsageSnapshot, UsageError>,
                           previous: UsageState, now: Date) -> UsageState {
        switch result {
        case .success(let snap):
            return .ok(snap)
        case .failure(let err):
            switch err {
            case .noToken, .unauthorized:
                return .needsAuth
            case .network, .decoding, .rateLimited:
                switch previous {
                case .ok(let snap):
                    return .stale(snap, since: now)
                case .stale(let snap, let since):
                    return .stale(snap, since: since)
                case .loading, .needsAuth:
                    return .loading
                }
            }
        }
    }
}

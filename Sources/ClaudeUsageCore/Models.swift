import Foundation

public enum ClaudeUsageCore {
    public static let version = "0.1.0"
}

public struct UsageWindow: Equatable, Sendable {
    public let percent: Double
    public let resetsAt: Date
    public let severity: String
    public init(percent: Double, resetsAt: Date, severity: String) {
        self.percent = percent; self.resetsAt = resetsAt; self.severity = severity
    }
}

public struct Credits: Equatable, Sendable {
    public let used: Double
    public let limit: Double
    public let currency: String
    public let decimalPlaces: Int
    public init(used: Double, limit: Double, currency: String, decimalPlaces: Int) {
        self.used = used; self.limit = limit; self.currency = currency; self.decimalPlaces = decimalPlaces
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let session: UsageWindow
    public let weekly: UsageWindow
    public let credits: Credits?
    public let fetchedAt: Date
    public init(session: UsageWindow, weekly: UsageWindow, credits: Credits?, fetchedAt: Date) {
        self.session = session; self.weekly = weekly; self.credits = credits; self.fetchedAt = fetchedAt
    }
}

public enum UsageState: Equatable, Sendable {
    case loading
    case ok(UsageSnapshot)
    case stale(UsageSnapshot, since: Date)
    case needsAuth
}

public enum UsageError: Error, Equatable, Sendable {
    case noToken
    case unauthorized
    case network(String)
    case decoding(String)
}

public enum RingColor: Equatable, Sendable { case green, amber, red }

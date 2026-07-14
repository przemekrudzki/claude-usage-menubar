import Foundation

public enum ClaudeUsageCore {
    public static let version = "0.1.0"
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let percent: Double
    public let resetsAt: Date
    public let severity: String
    public init(percent: Double, resetsAt: Date, severity: String) {
        self.percent = percent; self.resetsAt = resetsAt; self.severity = severity
    }
}

public struct ModelWeeklyUsage: Codable, Equatable, Sendable {
    public let modelID: String?
    public let displayName: String
    public let percent: Double
    public let resetsAt: Date?
    public let severity: String
    public init(modelID: String?, displayName: String, percent: Double,
                resetsAt: Date?, severity: String) {
        self.modelID = modelID; self.displayName = displayName; self.percent = percent
        self.resetsAt = resetsAt; self.severity = severity
    }
}

public struct Credits: Codable, Equatable, Sendable {
    public let used: Double
    public let limit: Double
    public let currency: String
    public let decimalPlaces: Int
    public init(used: Double, limit: Double, currency: String, decimalPlaces: Int) {
        self.used = used; self.limit = limit; self.currency = currency; self.decimalPlaces = decimalPlaces
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let session: UsageWindow
    public let weeklyAll: UsageWindow
    public let modelWeekly: [ModelWeeklyUsage]
    public let credits: Credits?
    public let fetchedAt: Date
    public init(session: UsageWindow, weeklyAll: UsageWindow,
                modelWeekly: [ModelWeeklyUsage] = [], credits: Credits?, fetchedAt: Date) {
        self.session = session; self.weeklyAll = weeklyAll; self.modelWeekly = modelWeekly
        self.credits = credits; self.fetchedAt = fetchedAt
    }
}

public enum UsageState: Equatable, Sendable {
    case loading
    case ok(UsageSnapshot)
    case stale(UsageSnapshot, since: Date)
    case needsAuth
    case unavailable(UsageError)
}

public enum UsageError: Error, Equatable, Sendable {
    case noToken
    case unauthorized
    case forbidden
    case credentialAccess(String)
    case credentialTimeout
    case requestTimeout
    case cancelled
    case network(String)
    case transport(Int)
    case httpStatus(Int)
    case decoding(String)
    case rateLimited(retryAfter: Double?)
    case responseTooLarge
}

public enum RingColor: Equatable, Sendable { case green, amber, red }

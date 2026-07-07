import Foundation

public protocol UsageFetching: Sendable {
    func fetch() async -> Result<UsageSnapshot, UsageError>
}

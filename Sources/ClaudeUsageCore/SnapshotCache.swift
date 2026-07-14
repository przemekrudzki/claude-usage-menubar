import Foundation

public protocol UsageSnapshotCaching: Sendable {
    func load() throws -> UsageSnapshot?
    func save(_ snapshot: UsageSnapshot) throws
}

public struct FileUsageSnapshotCache: UsageSnapshotCaching {
    private struct Envelope: Codable {
        let version: Int
        let snapshot: UsageSnapshot
    }

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            self.fileURL = base
                .appendingPathComponent("ClaudeUsage", isDirectory: true)
                .appendingPathComponent("usage-snapshot.json")
        }
    }

    public func load() throws -> UsageSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, Self.isValid(envelope.snapshot) else {
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
            return envelope.snapshot
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    public func save(_ snapshot: UsageSnapshot) throws {
        guard Self.isValid(snapshot) else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(Envelope(version: 1, snapshot: snapshot))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func isValid(_ snapshot: UsageSnapshot) -> Bool {
        let percentages = [snapshot.session.percent, snapshot.weeklyAll.percent]
            + snapshot.modelWeekly.map(\.percent)
        guard percentages.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000 }) else {
            return false
        }
        guard let credits = snapshot.credits else { return true }
        return credits.used.isFinite && credits.used >= 0
            && credits.limit.isFinite && credits.limit >= 0
            && (0...6).contains(credits.decimalPlaces)
    }
}

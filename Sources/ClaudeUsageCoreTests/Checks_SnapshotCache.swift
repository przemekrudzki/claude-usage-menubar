import Foundation
import ClaudeUsageCore

func snapshotCacheChecks() {
    t.group("SnapshotCache")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("snapshot.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let cache = FileUsageSnapshotCache(fileURL: url)
    let date = Date(timeIntervalSince1970: 1234)
    let window = UsageWindow(percent: 25, resetsAt: date.addingTimeInterval(3600),
                             severity: "normal")
    let snapshot = UsageSnapshot(session: window, weeklyAll: window,
                                 credits: nil, fetchedAt: date)
    do {
        try cache.save(snapshot)
        t.equal(try cache.load(), snapshot)
    } catch {
        t.expect(false, "valid snapshot should round-trip: \(error)")
    }

    do {
        try Data("not json".utf8).write(to: url, options: .atomic)
        _ = try cache.load()
        t.expect(false, "corrupt cache should report an error")
    } catch {
        t.expect(!FileManager.default.fileExists(atPath: url.path),
                 "corrupt cache should be removed")
    }
}

import Foundation

public enum Format {
    public static func countdown(to date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite else { return "now" }
        let secs: Int
        if interval >= Double(Int.max) {
            secs = Int.max
        } else if interval <= Double(Int.min) {
            secs = Int.min
        } else {
            secs = Int(interval)
        }
        if secs <= 0 { return "now" }
        if secs < 60 { return "<1m" }
        let mins = secs / 60
        let h = mins / 60
        let m = mins % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    public static func percent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), 0), 10_000))
    }
}

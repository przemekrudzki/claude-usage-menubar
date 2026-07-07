import Foundation

public enum Format {
    public static func countdown(to date: Date, now: Date) -> String {
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        if secs < 60 { return "<1m" }
        let mins = secs / 60
        let h = mins / 60
        let m = mins % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

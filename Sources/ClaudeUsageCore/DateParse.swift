import Foundation

public enum DateParse {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO8601 timestamps, tolerating variable-length fractional seconds
    /// by stripping them (we only need minute precision).
    public static func iso(_ s: String) -> Date? {
        let noFraction = s.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        return formatter.date(from: noFraction)
    }
}

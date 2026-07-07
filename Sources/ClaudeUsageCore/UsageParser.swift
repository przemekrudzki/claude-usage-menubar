import Foundation

public enum UsageParser {
    public static func snapshot(from data: Data, now: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding("root is not an object")
        }
        let limits = root["limits"] as? [[String: Any]] ?? []

        let session = try window(
            fromLimits: limits.first { ($0["kind"] as? String) == "session" },
            fallbackObject: root["five_hour"] as? [String: Any],
            label: "session"
        )

        let weeklyEntries = limits.filter { ($0["group"] as? String) == "weekly" }
        let topWeekly = weeklyEntries.max { percent($0) < percent($1) }
        let weekly = try window(
            fromLimits: topWeekly,
            fallbackObject: root["seven_day"] as? [String: Any],
            label: "weekly"
        )

        let credits = parseCredits(root["extra_usage"] as? [String: Any])
        return UsageSnapshot(session: session, weekly: weekly, credits: credits, fetchedAt: now)
    }

    private static func percent(_ e: [String: Any]) -> Double {
        (e["percent"] as? NSNumber)?.doubleValue ?? 0
    }

    private static func window(fromLimits limit: [String: Any]?,
                               fallbackObject fallback: [String: Any]?,
                               label: String) throws -> UsageWindow {
        if let l = limit,
           let resetStr = l["resets_at"] as? String, let reset = DateParse.iso(resetStr) {
            let pct = (l["percent"] as? NSNumber)?.doubleValue ?? 0
            let sev = (l["severity"] as? String) ?? "normal"
            return UsageWindow(percent: pct, resetsAt: reset, severity: sev)
        }
        if let f = fallback,
           let util = (f["utilization"] as? NSNumber)?.doubleValue,
           let resetStr = f["resets_at"] as? String, let reset = DateParse.iso(resetStr) {
            return UsageWindow(percent: util, resetsAt: reset, severity: "normal")
        }
        throw UsageError.decoding("missing \(label) window")
    }

    private static func parseCredits(_ e: [String: Any]?) -> Credits? {
        guard let e, (e["is_enabled"] as? Bool) == true else { return nil }
        let used = (e["used_credits"] as? NSNumber)?.doubleValue ?? 0
        let limit = (e["monthly_limit"] as? NSNumber)?.doubleValue ?? 0
        let currency = (e["currency"] as? String) ?? "USD"
        let places = (e["decimal_places"] as? NSNumber)?.intValue ?? 2
        return Credits(used: used, limit: limit, currency: currency, decimalPlaces: places)
    }
}

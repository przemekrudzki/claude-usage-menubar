import Foundation

public enum UsageParser {
    public static func snapshot(from data: Data, now: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decoding("root is not an object")
        }
        let limits = root["limits"] as? [[String: Any]] ?? []

        let session = try window(
            fromLimits: limits.filter { ($0["kind"] as? String) == "session" },
            fallbackObject: root["five_hour"] as? [String: Any],
            label: "session"
        )

        let weeklyAll = try window(
            fromLimits: limits.filter { ($0["kind"] as? String) == "weekly_all" },
            fallbackObject: root["seven_day"] as? [String: Any],
            label: "weekly"
        )
        let modelWeekly = parseModelWeekly(limits)

        let credits = parseCredits(root["extra_usage"] as? [String: Any])
        return UsageSnapshot(session: session, weeklyAll: weeklyAll,
                             modelWeekly: modelWeekly, credits: credits, fetchedAt: now)
    }

    /// `value is Bool` is not the test it looks like: Swift's NSNumber bridging
    /// reports true for the JSON numbers 0 and 1, so it would reject a genuine 0%
    /// reading — the state every window is in right after a reset. JSONSerialization
    /// hands back `__NSCFBoolean` for real booleans, which is what this checks.
    private static func decimal(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = decimal(value) else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 && result <= 10_000 ? result : nil
    }

    private static func amount(_ value: Any?) -> Double? {
        guard let number = decimal(value) else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private static func window(fromLimits limits: [[String: Any]],
                               fallbackObject fallback: [String: Any]?,
                               label: String) throws -> UsageWindow {
        let parsed = limits.compactMap { limit -> UsageWindow? in
            guard let pct = number(limit["percent"]),
                  let resetStr = limit["resets_at"] as? String,
                  let reset = DateParse.iso(resetStr) else { return nil }
            let sev = (limit["severity"] as? String) ?? "normal"
            return UsageWindow(percent: pct, resetsAt: reset, severity: sev)
        }
        if let result = parsed.max(by: { $0.percent < $1.percent }) {
            return result
        }
        if let f = fallback,
           let util = number(f["utilization"]),
           let resetStr = f["resets_at"] as? String, let reset = DateParse.iso(resetStr) {
            return UsageWindow(percent: util, resetsAt: reset, severity: "normal")
        }
        throw UsageError.decoding("missing \(label) window")
    }

    private static func parseModelWeekly(_ limits: [[String: Any]]) -> [ModelWeeklyUsage] {
        var seen = Set<String>()
        var result: [ModelWeeklyUsage] = []

        for limit in limits where (limit["kind"] as? String) == "weekly_scoped" {
            if let group = limit["group"] as? String, group != "weekly" { continue }
            guard let pct = number(limit["percent"]),
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let rawName = model["display_name"] as? String else { continue }

            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let rawID = (model["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = rawID.flatMap { $0.isEmpty ? nil : $0 }
            let key = modelID.map { "id:\($0.lowercased())" } ?? "name:\(name.lowercased())"
            guard seen.insert(key).inserted else { continue }

            let reset = (limit["resets_at"] as? String).flatMap(DateParse.iso)
            let sev = (limit["severity"] as? String) ?? "normal"
            result.append(ModelWeeklyUsage(modelID: modelID, displayName: name,
                                           percent: pct, resetsAt: reset, severity: sev))
        }
        return result
    }

    private static func parseCredits(_ e: [String: Any]?) -> Credits? {
        guard let e, (e["is_enabled"] as? Bool) == true else { return nil }
        guard let usedRaw = amount(e["used_credits"]),
              let limitRaw = amount(e["monthly_limit"]),
              let placesNumber = number(e["decimal_places"]),
              placesNumber.rounded() == placesNumber,
              (0...6).contains(Int(placesNumber)) else { return nil }
        let currency = (e["currency"] as? String) ?? "USD"
        let places = Int(placesNumber)
        // Amounts arrive in minor units (e.g. cents): 5000 with decimal_places 2 = 50.00.
        let scale = pow(10.0, Double(places))
        return Credits(used: usedRaw / scale, limit: limitRaw / scale,
                       currency: currency, decimalPlaces: places)
    }
}

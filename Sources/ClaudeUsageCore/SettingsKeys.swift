import Foundation

public enum SettingsKeys {
    public static let showRing = "showRing"
    public static let showSessionPercent = "showSessionPercent"
    public static let showCountdown = "showCountdown"
    public static let showWeekly = "showWeekly"
    public static let refreshInterval = "refreshInterval"   // stores RefreshInterval.rawValue
    public static let launchAtLogin = "launchAtLogin"

    /// Register defaults: all display elements on, 60s refresh.
    public static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            showRing: true,
            showSessionPercent: true,
            showCountdown: true,
            showWeekly: true,
            refreshInterval: RefreshInterval.s60.rawValue,
        ])
    }
}

public enum RefreshInterval: Double, CaseIterable {
    case s30 = 30, s60 = 60, m5 = 300
    public var label: String {
        switch self {
        case .s30: return "30 seconds"
        case .s60: return "1 minute"
        case .m5: return "5 minutes"
        }
    }
}

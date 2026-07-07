import Foundation

public enum Palette {
    public static func ring(percent: Double, severity: String) -> RingColor {
        switch severity.lowercased() {
        case "warning": return .amber
        case "critical", "exceeded": return .red
        default: break
        }
        switch percent {
        case ..<70: return .green
        case 70..<90: return .amber
        default: return .red
        }
    }
}

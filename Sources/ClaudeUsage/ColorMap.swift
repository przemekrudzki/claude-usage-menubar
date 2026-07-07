import SwiftUI
import ClaudeUsageCore

func color(for ring: RingColor) -> Color {
    switch ring {
    case .green: return .green
    case .amber: return .orange
    case .red: return .red
    }
}

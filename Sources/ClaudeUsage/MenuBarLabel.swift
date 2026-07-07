import SwiftUI
import ClaudeUsageCore

struct MenuBarLabel: View {
    let state: UsageState
    let now: Date

    @AppStorage(SettingsKeys.showRing) private var showRing = true
    @AppStorage(SettingsKeys.showSessionPercent) private var showSession = true
    @AppStorage(SettingsKeys.showCountdown) private var showCountdown = true
    @AppStorage(SettingsKeys.showWeekly) private var showWeekly = true

    var body: some View {
        switch state {
        case .loading, .needsAuth:
            HStack(spacing: 4) {
                RingView(percent: 0, color: .secondary, filled: false)
                    .frame(width: 14, height: 14)
            }
        case .ok(let snap):
            content(snap, dim: false)
        case .stale(let snap, _):
            content(snap, dim: true)
        }
    }

    @ViewBuilder
    private func content(_ snap: UsageSnapshot, dim: Bool) -> some View {
        let ring = Palette.ring(percent: snap.session.percent, severity: snap.session.severity)
        HStack(spacing: 4) {
            if showRing {
                RingView(percent: snap.session.percent, color: color(for: ring))
                    .frame(width: 14, height: 14)
            }
            if showSession {
                Text("\(Int(snap.session.percent.rounded()))%")
            }
            if showCountdown {
                Text(Format.countdown(to: snap.session.resetsAt, now: now))
            }
            if showWeekly {
                Text("7d \(Int(snap.weekly.percent.rounded()))%")
            }
        }
        .opacity(dim ? 0.5 : 1)
    }
}

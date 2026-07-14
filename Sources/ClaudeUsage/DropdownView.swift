import SwiftUI
import ClaudeUsageCore

struct DropdownView: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                content(now: ctx.date)
            }
            Divider()
            Button("Refresh now") { Task { await store.refresh(trigger: .manual) } }
            // SettingsLink does not surface the window in an LSUIElement app;
            // activate the app first, then open Settings explicitly.
            Button("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
        .task { await store.refresh(trigger: .menuOpen) }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch store.state {
        case .loading:
            ProgressView("Loading…")
        case .needsAuth:
            Text("Sign in to Claude Code to see usage.")
                .foregroundStyle(.secondary)
        case .unavailable(let error):
            Text(unavailableMessage(error))
                .foregroundStyle(.secondary)
        case .ok(let snap):
            breakdown(snap, now: now, footer: nil)
        case .stale(let snap, let since):
            breakdown(snap, now: now,
                      footer: "stale · couldn't reach Anthropic (\(Format.countdown(to: now, now: since)) ago)")
                .opacity(0.6)
        }
    }

    @ViewBuilder
    private func breakdown(_ snap: UsageSnapshot, now: Date, footer: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "5-hour session", percent: snap.session.percent,
                reset: "resets in \(Format.countdown(to: snap.session.resetsAt, now: now))",
                severity: snap.session.severity)
            row(title: "7-day - All models", percent: snap.weeklyAll.percent,
                reset: resetDate(snap.weeklyAll.resetsAt),
                severity: snap.weeklyAll.severity)
            ForEach(Array(snap.modelWeekly.enumerated()), id: \.offset) { _, usage in
                row(title: "7-day - \(usage.displayName)", percent: usage.percent,
                    reset: usage.resetsAt.map(resetDate) ?? "reset unavailable",
                    severity: usage.severity)
            }
            Text("Updated \(Format.countdown(to: now, now: snap.fetchedAt)) ago")
                .font(.caption2).foregroundStyle(.secondary)
            if let c = snap.credits {
                Text(String(format: "Extra credits: %.\(c.decimalPlaces)f / %.\(c.decimalPlaces)f %@",
                            c.used, c.limit, c.currency))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let footer {
                Text(footer).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(title: String, percent: Double, reset: String, severity: String) -> some View {
        HStack(spacing: 8) {
            RingView(percent: percent,
                     color: color(for: Palette.ring(percent: percent, severity: severity)))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading) {
                Text("\(title) — \(Format.percent(percent))%").font(.subheadline)
                Text(reset).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resetDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"
        return "resets \(f.string(from: d))"
    }

    private func unavailableMessage(_ error: UsageError) -> String {
        switch error {
        case .credentialTimeout, .requestTimeout:
            return "Keychain access timed out. Try refreshing."
        case .rateLimited:
            return "Anthropic rate-limited usage checks. Retrying later."
        case .noToken, .unauthorized, .forbidden:
            return "Sign in to Claude Code to see usage."
        case .cancelled:
            return "Usage refresh was cancelled."
        case .credentialAccess, .network, .transport, .httpStatus, .decoding, .responseTooLarge:
            return "Usage is temporarily unavailable."
        }
    }
}

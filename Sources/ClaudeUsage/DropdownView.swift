import SwiftUI
import ClaudeUsageCore

struct DropdownView: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: store.nextRetryAt == nil ? 60 : 1)) { ctx in
            VStack(alignment: .leading, spacing: 10) {
                content(now: ctx.date)
                Divider()
                refreshFooter(now: ctx.date)
                Divider()
                actions
            }
            .padding(12)
            .frame(width: 292)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await store.refresh(trigger: .menuOpen) }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch store.state {
        case .loading:
            stateMessage(
                title: "Loading usage",
                detail: "Reading your current Claude usage.",
                systemImage: "chart.donut",
                showsProgress: true
            )
        case .needsAuth:
            stateMessage(
                title: "Sign in to Claude Code",
                detail: "Complete sign-in in Terminal, then refresh.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        case .unavailable(let error):
            let message = unavailableMessage(error, now: now)
            stateMessage(title: message.title, detail: message.detail,
                         systemImage: message.systemImage)
        case .ok(let snap):
            breakdown(snap, now: now, cachedSince: nil)
        case .stale(let snap, let since):
            breakdown(snap, now: now, cachedSince: since)
        }
    }

    @ViewBuilder
    private func breakdown(_ snap: UsageSnapshot, now: Date, cachedSince: Date?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row(title: "5-hour session", percent: snap.session.percent,
                reset: "resets in \(Format.countdown(to: snap.session.resetsAt, now: now))",
                severity: snap.session.severity, isPrimary: true)

            Divider()

            row(title: "7-day, all models", percent: snap.weeklyAll.percent,
                reset: resetDate(snap.weeklyAll.resetsAt),
                severity: snap.weeklyAll.severity)

            if !snap.modelWeekly.isEmpty {
                Text("Model limits")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                if snap.modelWeekly.count > 3 {
                    ScrollView {
                        modelRows(snap.modelWeekly)
                    }
                    .frame(maxHeight: 150)
                } else {
                    modelRows(snap.modelWeekly)
                }
            }

            if let c = snap.credits {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Extra usage")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(creditAmount(c.used, credits: c)) / \(creditAmount(c.limit, credits: c))")
                        .monospacedDigit()
                }
                .font(.caption)
            }

            if cachedSince != nil {
                Label(cachedStatus(now: now), systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(cachedStatus(now: now))
            }
        }
    }

    @ViewBuilder
    private func modelRows(_ usages: [ModelWeeklyUsage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(usages.enumerated()), id: \.offset) { _, usage in
                row(title: usage.displayName, percent: usage.percent,
                    reset: usage.resetsAt.map(resetDate) ?? "reset unavailable",
                    severity: usage.severity)
            }
        }
    }

    private func row(title: String, percent: Double, reset: String,
                     severity: String, isPrimary: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RingView(percent: percent,
                     color: color(for: Palette.ring(percent: percent, severity: severity)),
                     lineWidth: isPrimary ? 3 : 2.5)
                .frame(width: isPrimary ? 24 : 22, height: isPrimary ? 24 : 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(isPrimary ? .subheadline.weight(.semibold) : .subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reset)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("\(Format.percent(percent))%")
                .font(isPrimary ? .title3.weight(.semibold) : .body.weight(.medium))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Format.percent(percent)) percent, \(severityDescription(percent: percent, severity: severity)), \(reset)")
    }

    private func resetDate(_ d: Date) -> String {
        "resets \(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
    }

    private func creditAmount(_ value: Double, credits: Credits) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = credits.currency
        formatter.minimumFractionDigits = credits.decimalPlaces
        formatter.maximumFractionDigits = credits.decimalPlaces
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.\(credits.decimalPlaces)f %@", value, credits.currency)
    }

    private func cachedStatus(now: Date) -> String {
        if store.isRefreshing { return "Showing cached usage while refreshing" }
        guard let error = store.lastError else { return "Showing cached usage" }
        switch error {
        case .rateLimited:
            if let retry = retryText(now: now) {
                return "Showing cached usage; \(retry.lowercased())"
            }
            return "Showing cached usage; temporarily rate-limited"
        case .tokenExpired:
            return "Showing cached usage; run Claude Code to refresh its token"
        case .noToken, .unauthorized, .forbidden:
            return "Showing cached usage; sign-in required"
        case .network, .transport:
            return "Showing cached usage; currently offline"
        case .credentialTimeout:
            return "Showing cached usage; Keychain access timed out"
        case .requestTimeout:
            return "Showing cached usage; refresh timed out"
        case .credentialAccess:
            return "Showing cached usage; credentials unavailable"
        case .httpStatus, .decoding, .responseTooLarge:
            return "Showing cached usage; last refresh failed"
        case .cancelled:
            return "Showing cached usage"
        }
    }

    private func unavailableMessage(_ error: UsageError, now: Date)
        -> (title: String, detail: String, systemImage: String) {
        switch error {
        case .credentialTimeout:
            return ("Keychain unavailable", "Reading Claude Code credentials timed out.",
                    "key.horizontal")
        case .requestTimeout:
            return ("Refresh timed out", "The usage service did not respond in time.",
                    "clock.badge.exclamationmark")
        case .rateLimited:
            return ("Temporarily rate-limited",
                    retryText(now: now) ?? "Claude Usage will retry automatically.",
                    "hourglass")
        case .tokenExpired:
            return ("Claude Code token expired",
                    "Run any Claude Code command to refresh it — this picks it up automatically.",
                    "key.horizontal")
        case .noToken, .unauthorized, .forbidden:
            return ("Sign in to Claude Code", "Complete sign-in in Terminal, then refresh.",
                    "person.crop.circle.badge.exclamationmark")
        case .cancelled:
            return ("Refresh cancelled", "Try refreshing again.", "xmark.circle")
        case .credentialAccess:
            return ("Credentials unavailable", "Claude Code credentials could not be read.",
                    "key.horizontal")
        case .network, .transport:
            return ("Can't refresh usage", "Check your internet connection and try again.",
                    "wifi.exclamationmark")
        case .httpStatus:
            return ("Usage service unavailable", "Claude Usage will retry automatically.",
                    "exclamationmark.icloud")
        case .decoding, .responseTooLarge:
            return ("Unexpected response", "The usage service returned unsupported data.",
                    "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func stateMessage(title: String, detail: String, systemImage: String,
                              showsProgress: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func refreshFooter(now: Date) -> some View {
        HStack(spacing: 8) {
            if let snapshot = displayedSnapshot {
                Text(lastUpdatedText(snapshot.fetchedAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let retry = retryText(now: now) {
                Text(retry)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                Task { await store.refresh(trigger: .manual) }
            } label: {
                HStack(spacing: 5) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(store.isRefreshing ? "Refreshing" : "Refresh")
                }
            }
            .controlSize(.small)
            // Never disabled by backoff: a manual refresh overrides it in the store,
            // so the countdown is information about the *automatic* retry, not a lock.
            .disabled(store.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                // SettingsLink does not surface the window in an LSUIElement app.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var displayedSnapshot: UsageSnapshot? {
        switch store.state {
        case .ok(let snapshot), .stale(let snapshot, _): return snapshot
        case .loading, .needsAuth, .unavailable: return nil
        }
    }

    private func retryText(now: Date) -> String? {
        guard let retryAt = store.nextRetryAt, retryAt > now else { return nil }
        return "Retrying in \(Format.countdown(to: retryAt, now: now))"
    }

    private func lastUpdatedText(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Updated just now" }
        return "Updated \(Format.countdown(to: now, now: date)) ago"
    }

    private func severityDescription(percent: Double, severity: String) -> String {
        switch Palette.ring(percent: percent, severity: severity) {
        case .green: return "within limit"
        case .amber: return "approaching limit"
        case .red: return "at or near limit"
        }
    }
}

import SwiftUI
import AppKit
import ClaudeUsageCore

/// The always-visible menu bar content. `MenuBarExtra` does not reliably render
/// a multi-element SwiftUI layout (or custom shapes) directly, so we rasterize the
/// composed view into a single colored `NSImage` (`isTemplate = false`) — this keeps
/// the ring's severity color. Because a non-template image is shown as-is, the text
/// color can't auto-adapt to a wallpaper-darkened menu bar (which the appearance API
/// can't detect), so its color follows the user's "menu bar text color" setting.
struct MenuBarLabel: View {
    let state: UsageState
    let now: Date

    @AppStorage(SettingsKeys.showRing) private var showRing = true
    @AppStorage(SettingsKeys.showSessionPercent) private var showSession = true
    @AppStorage(SettingsKeys.showCountdown) private var showCountdown = true
    @AppStorage(SettingsKeys.showWeekly) private var showWeekly = true
    @AppStorage(SettingsKeys.menuBarTextColor) private var textColorMode = MenuBarTextColor.auto.rawValue

    var body: some View {
        Image(nsImage: rendered())
    }

    private var textColor: Color {
        switch MenuBarTextColor(rawValue: textColorMode) ?? .auto {
        case .light: return .white
        case .dark: return .black
        case .auto:
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? .white : .black
        }
    }

    @MainActor
    private func rendered() -> NSImage {
        let renderer = ImageRenderer(content: composed)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            return NSImage(systemSymbolName: "chart.donut", accessibilityDescription: "Claude Usage")
                ?? NSImage(size: NSSize(width: 15, height: 15))
        }
        let image = NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        )
        image.isTemplate = false
        return image
    }

    @ViewBuilder
    private var composed: some View {
        switch state {
        case .loading, .needsAuth, .unavailable:
            RingView(percent: 0, color: textColor, filled: false)
                .frame(width: 15, height: 15)
                .padding(2)
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
            if !showRing && !showSession && !showCountdown && !showWeekly {
                RingView(percent: 0, color: textColor, filled: false)
                    .frame(width: 15, height: 15)
            }
            if showRing {
                RingView(percent: snap.session.percent, color: color(for: ring))
                    .frame(width: 15, height: 15)
            }
            Group {
                if showSession {
                    Text("\(Format.percent(snap.session.percent))%")
                }
                if showCountdown {
                    Text(Format.countdown(to: snap.session.resetsAt, now: now))
                }
                if showWeekly {
                    Text("7d \(Format.percent(snap.weeklyAll.percent))%")
                }
            }
            .foregroundStyle(textColor)
        }
        .font(.system(size: 13))
        .opacity(dim ? 0.5 : 1)
        .padding(.vertical, 1)
        .padding(.horizontal, 2)
    }
}

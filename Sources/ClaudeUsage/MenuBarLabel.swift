import SwiftUI
import ClaudeUsageCore

/// The always-visible menu bar content. `MenuBarExtra` does not reliably render
/// a multi-element SwiftUI layout (or custom shapes like the ring) directly as
/// its label, so we rasterize the composed view into an `NSImage` and show that.
/// The image is a template (`isTemplate = true`) so macOS tints it to match the
/// menu bar's text color in every appearance — including light mode with a
/// wallpaper-darkened bar, which `effectiveAppearance` can't detect. The bar
/// ring is therefore monochrome; the color-coded severity rings live in the
/// dropdown.
struct MenuBarLabel: View {
    let state: UsageState
    let now: Date

    @AppStorage(SettingsKeys.showRing) private var showRing = true
    @AppStorage(SettingsKeys.showSessionPercent) private var showSession = true
    @AppStorage(SettingsKeys.showCountdown) private var showCountdown = true
    @AppStorage(SettingsKeys.showWeekly) private var showWeekly = true

    var body: some View {
        Image(nsImage: rendered())
    }

    @MainActor
    private func rendered() -> NSImage {
        let renderer = ImageRenderer(content: composed)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return NSImage() }
        let image = NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        )
        image.isTemplate = true
        return image
    }

    @ViewBuilder
    private var composed: some View {
        switch state {
        case .loading, .needsAuth:
            RingView(percent: 0, color: .secondary, filled: false)
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
            if showRing {
                RingView(percent: snap.session.percent, color: color(for: ring))
                    .frame(width: 15, height: 15)
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
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .opacity(dim ? 0.5 : 1)
        .padding(.vertical, 1)
        .padding(.horizontal, 2)
    }
}

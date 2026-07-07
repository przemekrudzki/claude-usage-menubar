import SwiftUI
import ClaudeUsageCore

struct SettingsView: View {
    @AppStorage(SettingsKeys.showRing) private var showRing = true
    @AppStorage(SettingsKeys.showSessionPercent) private var showSession = true
    @AppStorage(SettingsKeys.showCountdown) private var showCountdown = true
    @AppStorage(SettingsKeys.showWeekly) private var showWeekly = true
    @AppStorage(SettingsKeys.refreshInterval) private var interval = RefreshInterval.s60.rawValue
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Ring gauge", isOn: $showRing)
                Toggle("5-hour %", isOn: $showSession)
                Toggle("Countdown to reset", isOn: $showCountdown)
                Toggle("Weekly %", isOn: $showWeekly)
            }
            Section("Behavior") {
                Picker("Refresh every", selection: $interval) {
                    ForEach(RefreshInterval.allCases, id: \.rawValue) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.setEnabled(on) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .padding()
    }
}

import SwiftUI
import AppKit
import ClaudeUsageCore

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let runtime = AppRuntime.shared
    @AppStorage(SettingsKeys.refreshInterval) private var interval = RefreshInterval.s60.rawValue

    init() {
        SettingsKeys.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(store: runtime.store)
        } label: {
            MenuBarLabel(state: runtime.store.state, now: Date())
                .onChange(of: interval) { _, newValue in
                    runtime.updatePollingInterval(newValue)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

import SwiftUI
import ClaudeUsageCore

@main
struct ClaudeUsageApp: App {
    @State private var store = UsageStore(fetcher: UsageClient())
    @AppStorage(SettingsKeys.refreshInterval) private var interval = RefreshInterval.s60.rawValue
    @AppStorage("didFirstRun") private var didFirstRun = false

    init() {
        SettingsKeys.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownView(store: store)
        } label: {
            MenuBarLabel(state: store.state, now: Date())
                .task {
                    store.start(intervalSeconds: interval)
                    if !didFirstRun {
                        LoginItem.setEnabled(true)
                        didFirstRun = true
                    }
                }
                .onChange(of: interval) { _, newValue in
                    store.start(intervalSeconds: newValue)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

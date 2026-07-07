import SwiftUI
import AppKit
import ClaudeUsageCore

@main
struct ClaudeUsageApp: App {
    @State private var store = UsageStore(fetcher: UsageClient())
    @State private var connectivity = ConnectivityMonitor()
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
                    // Refresh the instant the network comes back (e.g. booted offline).
                    connectivity.onBecameOnline = { Task { await store.refresh() } }
                    connectivity.start()
                    if !didFirstRun {
                        if LoginItem.setEnabled(true) { didFirstRun = true }
                    }
                }
                .onChange(of: interval) { _, newValue in
                    store.start(intervalSeconds: newValue)
                }
                // Refresh when the Mac wakes from sleep.
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    Task { await store.refresh() }
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

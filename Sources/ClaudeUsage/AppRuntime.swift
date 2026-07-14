import AppKit
import ClaudeUsageCore
import Foundation
import OSLog

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let store = UsageStore(fetcher: UsageClient(), cache: FileUsageSnapshotCache())
    private let connectivity = ConnectivityMonitor()
    private let logger = Logger(subsystem: "com.przemek.ClaudeUsageMenuBar", category: "lifecycle")
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    private var generation = 0

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        generation += 1
        let generation = generation

        let defaults = UserDefaults.standard
        let storedInterval = defaults.double(forKey: SettingsKeys.refreshInterval)
        let interval = RefreshInterval(rawValue: storedInterval) ?? .s60
        if storedInterval != interval.rawValue {
            defaults.set(interval.rawValue, forKey: SettingsKeys.refreshInterval)
        }

        connectivity.onBecameOnline = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.generation == generation else { return }
                await self.store.refresh(trigger: .connectivity)
            }
        }
        connectivity.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.generation == generation else { return }
                await self.store.refresh(trigger: .wake)
            }
        }
        store.start(intervalSeconds: interval.rawValue)

        if !defaults.bool(forKey: "didFirstRun") {
            switch LoginItem.setEnabled(true) {
            case .applied, .pendingApproval:
                defaults.set(true, forKey: "didFirstRun")
            case .failed:
                break
            }
        }
        logger.info("Application runtime started")
    }

    func updatePollingInterval(_ value: Double) {
        let normalized = RefreshInterval(rawValue: value) ?? .s60
        if normalized.rawValue != value {
            UserDefaults.standard.set(normalized.rawValue, forKey: SettingsKeys.refreshInterval)
        }
        guard started else { return }
        store.start(intervalSeconds: normalized.rawValue)
    }

    func stop() {
        guard started else { return }
        started = false
        generation += 1
        store.stop()
        connectivity.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        logger.info("Application runtime stopped")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppRuntime.shared.stop()
    }
}

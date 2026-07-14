import Foundation
import Network

/// Watches network reachability and fires `onBecameOnline` when the path
/// transitions from unsatisfied to satisfied — e.g. after the Mac boots offline
/// (the login item launches before Wi-Fi connects) and then joins a network.
/// Without this, a fresh boot would show nothing until the next poll tick.
@MainActor
final class ConnectivityMonitor {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.przemek.ClaudeUsageMenuBar.connectivity")
    private var wasSatisfied = true
    private var started = false
    private var generation = 0

    /// Called on the main queue each time connectivity is (re)established.
    var onBecameOnline: (() -> Void)?

    func start() {
        guard !started else { return }
        started = true
        generation += 1
        let generation = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.started, self.generation == generation else { return }
                let satisfied = path.status == .satisfied
                let regained = satisfied && !self.wasSatisfied
                self.wasSatisfied = satisfied
                if regained { self.onBecameOnline?() }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard started else { return }
        generation += 1
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        onBecameOnline = nil
        started = false
    }
}

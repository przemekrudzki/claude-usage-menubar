import Foundation
import Network

/// Watches network reachability and fires `onBecameOnline` when the path
/// transitions from unsatisfied to satisfied — e.g. after the Mac boots offline
/// (the login item launches before Wi-Fi connects) and then joins a network.
/// Without this, a fresh boot would show nothing until the next poll tick.
final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.przemek.ClaudeUsageMenuBar.connectivity")
    private var wasSatisfied = true
    private var started = false

    /// Called on the main queue each time connectivity is (re)established.
    var onBecameOnline: (() -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let regained = satisfied && !self.wasSatisfied
            self.wasSatisfied = satisfied
            if regained {
                DispatchQueue.main.async { self.onBecameOnline?() }
            }
        }
        monitor.start(queue: queue)
    }
}

import SwiftUI

@main
struct ClaudeUsageApp: App {
    var body: some Scene {
        MenuBarExtra("Claude Usage") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

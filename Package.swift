// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeUsageCore"),
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["ClaudeUsageCore"]
        ),
        // Hand-rolled test runner (executable). XCTest / Swift Testing are
        // unavailable under Command Line Tools (no Xcode), so tests run via
        // `swift run ClaudeUsageCoreTests`.
        .executableTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

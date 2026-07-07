import Foundation

/// Minimal test harness. XCTest and Swift Testing require Xcode, which is not
/// installed; this runs as a plain executable via `swift run ClaudeUsageCoreTests`.
/// Each check records a pass/fail; `finish()` prints a summary and exits non-zero
/// if anything failed, so it works as a CI/TDD gate.
final class TestKit {
    static let shared = TestKit()
    private init() {}

    private(set) var failures = 0
    private var total = 0
    private var currentGroup = ""

    /// Names the block of checks that follow (printed once, for readable output).
    func group(_ name: String) {
        currentGroup = name
        print("• \(name)")
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                _ file: String = #fileID, _ line: Int = #line) {
        total += 1
        if !condition {
            failures += 1
            print("  ✗ \(message()) [\(file):\(line)]")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T,
                             _ file: String = #fileID, _ line: Int = #line) {
        expect(actual == expected, "expected \(expected), got \(actual)", file, line)
    }

    @discardableResult
    func notNil<T>(_ value: T?, _ message: @autoclosure () -> String = "value was nil",
                   _ file: String = #fileID, _ line: Int = #line) -> T? {
        expect(value != nil, message(), file, line)
        return value
    }

    func close(_ actual: Double, _ expected: Double, _ accuracy: Double,
               _ file: String = #fileID, _ line: Int = #line) {
        expect(abs(actual - expected) <= accuracy,
               "expected \(expected) ± \(accuracy), got \(actual)", file, line)
    }

    /// Passes when `body` throws.
    func throwsError(_ label: String, _ body: () throws -> Void,
                     _ file: String = #fileID, _ line: Int = #line) {
        total += 1
        do {
            try body()
            failures += 1
            print("  ✗ \(label): expected a throw but none occurred [\(file):\(line)]")
        } catch {
            // expected
        }
    }

    func finish() -> Never {
        if failures == 0 {
            print("PASS (\(total) checks)")
        } else {
            print("FAIL (\(failures)/\(total) checks failed)")
        }
        exit(failures == 0 ? 0 : 1)
    }
}

/// Shared instance used by every checks function.
let t = TestKit.shared

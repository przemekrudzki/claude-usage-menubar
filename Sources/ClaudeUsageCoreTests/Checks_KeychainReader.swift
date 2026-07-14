import Foundation
import ClaudeUsageCore

struct StubSecurityRunner: SecurityCommandRunning {
    let result: Result<Data, SecurityCommandError>
    func passwordData(service: String, timeout: Duration) async throws -> Data {
        try result.get()
    }
}

func keychainReaderChecks() async {
    t.group("KeychainReader")
    let ok = Data(#"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r"}}"#.utf8)
    t.equal((try? KeychainReader.token(fromJSON: ok)) ?? "", "tok-123")
    let missing = Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8)
    t.throwsError("missing token throws") { _ = try KeychainReader.token(fromJSON: missing) }
    t.throwsError("malformed throws") { _ = try KeychainReader.token(fromJSON: Data("nonsense".utf8)) }
    // `security find-generic-password -w` output ends with a newline
    let trailingNewline = Data((#"{"claudeAiOauth":{"accessToken":"tok-123"}}"# + "\n").utf8)
    t.equal((try? KeychainReader.token(fromJSON: trailingNewline)) ?? "", "tok-123")

    let runner = StubSecurityRunner(result: .success(ok))
    t.equal((try? await KeychainReader.readToken(runner: runner)) ?? "", "tok-123")
    do {
        _ = try await KeychainReader.readToken(
            runner: StubSecurityRunner(result: .failure(.timedOut))
        )
        t.expect(false, "timeout should throw")
    } catch let error as UsageError {
        t.equal(error, .credentialTimeout)
    } catch {
        t.expect(false, "timeout should remain a UsageError")
    }

    // Opt-in end-to-end check against the real Keychain (reads the actual item, so
    // it is gated): CLAUDE_USAGE_KEYCHAIN_IT=1 swift run ClaudeUsageCoreTests
    if ProcessInfo.processInfo.environment["CLAUDE_USAGE_KEYCHAIN_IT"] == "1" {
        t.equal(((try? await KeychainReader.readToken()) ?? "").isEmpty, false)
    }
}

import Foundation
import ClaudeUsageCore

func keychainReaderChecks() {
    t.group("KeychainReader")
    let ok = Data(#"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r"}}"#.utf8)
    t.equal((try? KeychainReader.token(fromJSON: ok)) ?? "", "tok-123")
    let missing = Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8)
    t.throwsError("missing token throws") { _ = try KeychainReader.token(fromJSON: missing) }
    t.throwsError("malformed throws") { _ = try KeychainReader.token(fromJSON: Data("nonsense".utf8)) }
    // `security find-generic-password -w` output ends with a newline
    let trailingNewline = Data((#"{"claudeAiOauth":{"accessToken":"tok-123"}}"# + "\n").utf8)
    t.equal((try? KeychainReader.token(fromJSON: trailingNewline)) ?? "", "tok-123")

    // Opt-in end-to-end check against the real Keychain (reads the actual item, so
    // it is gated): CLAUDE_USAGE_KEYCHAIN_IT=1 swift run ClaudeUsageCoreTests
    if ProcessInfo.processInfo.environment["CLAUDE_USAGE_KEYCHAIN_IT"] == "1" {
        t.equal(((try? KeychainReader.readToken()) ?? "").isEmpty, false)
    }
}

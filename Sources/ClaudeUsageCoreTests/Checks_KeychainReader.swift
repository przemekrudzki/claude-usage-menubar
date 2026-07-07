import Foundation
import ClaudeUsageCore

func keychainReaderChecks() {
    t.group("KeychainReader")
    let ok = Data(#"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r"}}"#.utf8)
    t.equal((try? KeychainReader.token(fromJSON: ok)) ?? "", "tok-123")
    let missing = Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8)
    t.throwsError("missing token throws") { _ = try KeychainReader.token(fromJSON: missing) }
    t.throwsError("malformed throws") { _ = try KeychainReader.token(fromJSON: Data("nonsense".utf8)) }
}

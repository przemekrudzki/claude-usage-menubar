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

    // expiresAt: milliseconds since the epoch (what Claude Code writes), seconds, and junk
    let withExpiry = Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1754467200000}}"#.utf8)
    t.equal((try? KeychainReader.credential(fromJSON: withExpiry))?.expiresAt,
            Date(timeIntervalSince1970: 1_754_467_200))
    let secondsExpiry = Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1754467200}}"#.utf8)
    t.equal((try? KeychainReader.credential(fromJSON: secondsExpiry))?.expiresAt,
            Date(timeIntervalSince1970: 1_754_467_200))
    let stringExpiry = Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":"1754467200000"}}"#.utf8)
    t.equal((try? KeychainReader.credential(fromJSON: stringExpiry))?.expiresAt,
            Date(timeIntervalSince1970: 1_754_467_200))
    for junk in [#""expiresAt":0"#, #""expiresAt":-5"#, #""expiresAt":"soon""#,
                 #""expiresAt":null"#, #""expiresAt":123"#] {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"t",\#(junk)}}"#.utf8)
        t.expect((try? KeychainReader.credential(fromJSON: data))?.expiresAt == nil,
                 "implausible expiry \(junk) must be ignored")
    }
    t.expect((try? KeychainReader.credential(fromJSON: ok))?.expiresAt == nil,
             "absent expiry stays nil")

    // An unreadable expiry must never brick the app: no expiry means "assume usable".
    let at = Date(timeIntervalSince1970: 1_754_467_200)
    t.expect(!ClaudeCredential(token: "t").isExpired(now: at), "no expiry is never expired")
    t.expect(ClaudeCredential(token: "t", expiresAt: at).isExpired(now: at), "at expiry is expired")
    t.expect(ClaudeCredential(token: "t", expiresAt: at.addingTimeInterval(30))
        .isExpired(now: at), "inside the skew window is expired")
    t.expect(!ClaudeCredential(token: "t", expiresAt: at.addingTimeInterval(600))
        .isExpired(now: at), "a live token is not expired")

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
        let live = try? await KeychainReader.readCredential()
        t.equal((live?.token ?? "").isEmpty, false)
        // Expiry only — never the token itself.
        print("  ℹ expiresAt=\(live?.expiresAt.map(String.init(describing:)) ?? "none") " +
              "expired=\(live?.isExpired(now: Date()) ?? false)")
    }
}

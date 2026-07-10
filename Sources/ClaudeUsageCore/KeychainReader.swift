import Foundation
import Security

public enum KeychainReader {
    static let service = "Claude Code-credentials"

    public static func token(fromJSON data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { throw UsageError.noToken }
        return token
    }

    public static func readToken() throws -> String {
        // Read via /usr/bin/security: Claude Code creates the item through that tool,
        // so it is permanently in the item's ACL (`apple-tool:` partition) and the read
        // never triggers the per-app Keychain prompt. Reading with SecItemCopyMatching
        // would key the grant on this app's cdhash (no Team ID), which changes every
        // rebuild — that's what caused the endless re-prompts.
        if let data = readViaSecurityCLI() {
            return try token(fromJSON: data)
        }
        return try readViaSecItem()
    }

    static func readViaSecurityCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    // Fallback only; may show the per-app Keychain prompt (and blocks until answered).
    static func readViaSecItem() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw UsageError.noToken
        }
        return try token(fromJSON: data)
    }
}

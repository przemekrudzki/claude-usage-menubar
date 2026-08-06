import Foundation
import Security
import Darwin

public enum SecurityCommandError: Error, Equatable, Sendable {
    case launchFailed(String)
    case exited(Int32)
    case timedOut
    case emptyOutput
}

public protocol SecurityCommandRunning: Sendable {
    func passwordData(service: String, timeout: Duration) async throws -> Data
}

public struct SecurityCommandRunner: SecurityCommandRunning {
    public init() {}

    public func passwordData(service: String, timeout: Duration) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let operation = SecurityProcessOperation(process: process, stdout: stdout)
        do {
            try process.run()
        } catch {
            throw SecurityCommandError.launchFailed(error.localizedDescription)
        }

        do {
            let data = try await withTaskCancellationHandler {
                try await operation.value(timeout: timeout)
            } onCancel: {
                operation.cancel()
            }
            try Task.checkCancellation()
            return data
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

private final class SecurityProcessOperation: @unchecked Sendable {
    private let process: Process
    private let stdout: Pipe
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    init(process: Process, stdout: Pipe) {
        self.process = process
        self.stdout = stdout
        process.terminationHandler = { [weak self] process in
            self?.processExited(process)
        }
    }

    func value(timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result = pendingResult {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.timeoutReached()
            }
            lock.unlock()
        }
    }

    func cancel() {
        if finish(.failure(CancellationError())) { stopProcess() }
    }

    private func timeoutReached() {
        if finish(.failure(SecurityCommandError.timedOut)) { stopProcess() }
    }

    private func processExited(_ process: Process) {
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            _ = finish(.failure(SecurityCommandError.exited(process.terminationStatus)))
        } else if data.isEmpty {
            _ = finish(.failure(SecurityCommandError.emptyOutput))
        } else {
            _ = finish(.success(data))
        }
    }

    @discardableResult
    private func finish(_ result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
        return true
    }

    private func stopProcess() {
        let process = self.process
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// The Claude Code OAuth credential as stored in the Keychain. Claude Code owns the
/// refresh cycle; this app only reads what is there and reports when it has gone stale.
public struct ClaudeCredential: Equatable, Sendable {
    public let token: String
    /// Absent when Claude Code stores no (or an implausible) `expiresAt`.
    public let expiresAt: Date?

    public init(token: String, expiresAt: Date? = nil) {
        self.token = token
        self.expiresAt = expiresAt
    }

    /// True once the token is at, or within `skew` of, its expiry.
    ///
    /// Sending an expired token is not merely useless: three rejected requests in a
    /// row earn an hour-long 429 lockout from the API, which is exactly how this app
    /// used to end up stuck on cached data all day. Checking locally costs nothing.
    public func isExpired(now: Date, skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= skew
    }
}

public enum KeychainReader {
    static let service = "Claude Code-credentials"

    public static func token(fromJSON data: Data) throws -> String {
        try credential(fromJSON: data).token
    }

    public static func credential(fromJSON data: Data) throws -> ClaudeCredential {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { throw UsageError.noToken }
        return ClaudeCredential(token: token, expiresAt: expiry(from: oauth["expiresAt"]))
    }

    /// Claude Code writes `expiresAt` as milliseconds since the epoch. Seconds are
    /// accepted too, and anything not plausibly a date is discarded rather than
    /// treated as an expiry in 1970 — a bad parse must never brick the app.
    static func expiry(from value: Any?) -> Date? {
        guard let raw = (value as? Double) ?? (value as? String).flatMap(Double.init),
              raw.isFinite, raw > 0 else { return nil }
        let seconds = raw > 1e11 ? raw / 1000 : raw
        guard seconds > 978_307_200 else { return nil }  // before 2001-01-01: not credible
        return Date(timeIntervalSince1970: seconds)
    }

    public static func readToken(runner: any SecurityCommandRunning = SecurityCommandRunner(),
                                 timeout: Duration = .seconds(8),
                                 allowInteractiveFallback: Bool = false) async throws -> String {
        try await readCredential(runner: runner, timeout: timeout,
                                 allowInteractiveFallback: allowInteractiveFallback).token
    }

    public static func readCredential(
        runner: any SecurityCommandRunning = SecurityCommandRunner(),
        timeout: Duration = .seconds(8),
        allowInteractiveFallback: Bool = false
    ) async throws -> ClaudeCredential {
        // Read via /usr/bin/security: Claude Code creates the item through that tool,
        // so it is permanently in the item's ACL (`apple-tool:` partition) and the read
        // never triggers the per-app Keychain prompt. Reading with SecItemCopyMatching
        // would key the grant on this app's cdhash (no Team ID), which changes every
        // rebuild — that's what caused the endless re-prompts.
        do {
            let data = try await runner.passwordData(service: service, timeout: timeout)
            return try credential(fromJSON: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch SecurityCommandError.timedOut {
            throw UsageError.credentialTimeout
        } catch let error as SecurityCommandError {
            guard allowInteractiveFallback else {
                switch error {
                case .exited, .emptyOutput:
                    throw UsageError.noToken
                case .launchFailed(let message):
                    throw UsageError.credentialAccess(message)
                case .timedOut:
                    throw UsageError.credentialTimeout
                }
            }
        }
        return try readViaSecItem()
    }

    // Fallback only; may show the per-app Keychain prompt (and blocks until answered).
    static func readViaSecItem() throws -> ClaudeCredential {
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
        return try credential(fromJSON: data)
    }
}

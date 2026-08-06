import Foundation
import OSLog

public final class UsageClient: UsageFetching {
    private let credentialProvider: @Sendable () async throws -> ClaudeCredential
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let maxResponseBytes: Int
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let logger = Logger(subsystem: "com.przemek.ClaudeUsageMenuBar", category: "usage-client")

    public init(credentialProvider: @escaping @Sendable () async throws -> ClaudeCredential = {
                    try await KeychainReader.readCredential()
                },
                session: URLSession? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                maxResponseBytes: Int = 512 * 1024) {
        self.credentialProvider = credentialProvider
        self.session = session ?? Self.makeSession()
        self.now = now
        self.maxResponseBytes = max(1, maxResponseBytes)
    }

    /// Convenience for callers that only have a bare token (no expiry to check).
    public convenience init(tokenProvider: @escaping @Sendable () async throws -> String,
                            session: URLSession? = nil,
                            now: @escaping @Sendable () -> Date = { Date() },
                            maxResponseBytes: Int = 512 * 1024) {
        self.init(credentialProvider: { ClaudeCredential(token: try await tokenProvider()) },
                  session: session, now: now, maxResponseBytes: maxResponseBytes)
    }

    public func fetch() async -> Result<UsageSnapshot, UsageError> {
        let credential: ClaudeCredential
        do { credential = try await credentialProvider() }
        catch let e as UsageError { return .failure(e) }
        catch is CancellationError { return .failure(.cancelled) }
        catch { return .failure(.noToken) }

        // Claude Code refreshes this token only when it runs, so after an idle night
        // the stored one is dead. Requesting with it would earn a 401 — and three of
        // those in a row get the account 429'd for an hour.
        if credential.isExpired(now: now()) {
            let age = credential.expiresAt.map { now().timeIntervalSince($0) } ?? 0
            logger.notice("Stored access token expired \(age, privacy: .public)s ago; skipping the request")
            return .failure(.tokenExpired)
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (bytes, response) = try await session.bytes(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    return .failure(.unauthorized)
                }
                if http.statusCode == 403 {
                    return .failure(.forbidden)
                }
                if http.statusCode == 429 {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { Self.retryDelay(from: $0, now: now()) }
                    return .failure(.rateLimited(retryAfter: retryAfter))
                }
                if !(200...299).contains(http.statusCode) {
                    return .failure(.httpStatus(http.statusCode))
                }
            }
            var data = Data()
            data.reserveCapacity(min(maxResponseBytes, 16 * 1024))
            for try await byte in bytes {
                guard data.count < maxResponseBytes else {
                    return .failure(.responseTooLarge)
                }
                data.append(byte)
            }
            let snap = try UsageParser.snapshot(from: data, now: now())
            return .success(snap)
        } catch let e as UsageError {
            return .failure(e)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            return .failure(.cancelled)
        } catch let error as URLError {
            logger.error("Request failed with URL error \(error.code.rawValue, privacy: .public)")
            return .failure(.transport(error.code.rawValue))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private static func retryDelay(from value: String, now: Date) -> Double? {
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

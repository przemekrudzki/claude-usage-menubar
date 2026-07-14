import Foundation
import OSLog

public final class UsageClient: UsageFetching {
    private let tokenProvider: @Sendable () async throws -> String
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let maxResponseBytes: Int
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let logger = Logger(subsystem: "com.przemek.ClaudeUsageMenuBar", category: "usage-client")

    public init(tokenProvider: @escaping @Sendable () async throws -> String = {
                    try await KeychainReader.readToken()
                },
                session: URLSession? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                maxResponseBytes: Int = 512 * 1024) {
        self.tokenProvider = tokenProvider
        self.session = session ?? Self.makeSession()
        self.now = now
        self.maxResponseBytes = max(1, maxResponseBytes)
    }

    public func fetch() async -> Result<UsageSnapshot, UsageError> {
        let token: String
        do { token = try await tokenProvider() }
        catch let e as UsageError { return .failure(e) }
        catch is CancellationError { return .failure(.cancelled) }
        catch { return .failure(.noToken) }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

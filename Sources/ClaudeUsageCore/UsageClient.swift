import Foundation

public final class UsageClient: UsageFetching {
    private let tokenProvider: @Sendable () throws -> String
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(tokenProvider: @escaping @Sendable () throws -> String = { try KeychainReader.readToken() },
                session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    public func fetch() async -> Result<UsageSnapshot, UsageError> {
        let token: String
        do { token = try tokenProvider() }
        catch let e as UsageError { return .failure(e) }
        catch { return .failure(.noToken) }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                return .failure(.unauthorized)
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.network("HTTP \(http.statusCode)"))
            }
            let snap = try UsageParser.snapshot(from: data, now: now())
            return .success(snap)
        } catch let e as UsageError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

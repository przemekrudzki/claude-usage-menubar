import Foundation
import ClaudeUsageCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedRequest = request
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func usageClientChecks() async {
    t.group("UsageClient")
    let c1 = UsageClient(tokenProvider: { throw UsageError.noToken })
    t.equal(await c1.fetch(), .failure(.noToken))

    StubURLProtocol.status = 401
    StubURLProtocol.body = Data("unauthorized".utf8)
    let c2 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
    t.equal(await c2.fetch(), .failure(.unauthorized))

    StubURLProtocol.status = 200
    StubURLProtocol.body = Data(#"{"limits":[{"kind":"session","group":"session","percent":40,"severity":"normal","resets_at":"2026-07-07T19:40:00+00:00"},{"kind":"weekly_all","group":"weekly","percent":20,"severity":"normal","resets_at":"2026-07-11T08:00:00+00:00"},{"kind":"weekly_scoped","group":"weekly","percent":30,"severity":"warning","resets_at":"2026-07-11T08:00:00+00:00","scope":{"model":{"id":"fable","display_name":"Fable"}}}],"extra_usage":{"is_enabled":false}}"#.utf8)
    let c3 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
    if case .success(let snap) = await c3.fetch() {
        t.equal(snap.session.percent, 40)
        t.equal(snap.weeklyAll.percent, 20)
        t.equal(snap.modelWeekly.first?.displayName, "Fable")
        t.equal(snap.modelWeekly.first?.percent, 30)
    } else {
        t.expect(false, "expected success")
    }
    t.equal(StubURLProtocol.capturedRequest?.httpMethod, "GET")
    t.equal(StubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    t.equal(StubURLProtocol.capturedRequest?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")

    StubURLProtocol.status = 200
    StubURLProtocol.body = Data("{}".utf8)
    let c4 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
    if case .failure(.decoding) = await c4.fetch() {
        t.expect(true, "decoding path")
    } else {
        t.expect(false, "expected .decoding failure on malformed body")
    }

    StubURLProtocol.status = 429
    StubURLProtocol.body = Data("rate limited".utf8)
    StubURLProtocol.headers = ["Retry-After": "300"]
    let c5 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
    t.equal(await c5.fetch(), .failure(.rateLimited(retryAfter: 300)))

    StubURLProtocol.headers = ["Retry-After": "Thu, 01 Jan 1970 00:18:20 GMT"]
    let c6 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session(),
                         now: { Date(timeIntervalSince1970: 1000) })
    t.equal(await c6.fetch(), .failure(.rateLimited(retryAfter: 100)))

    StubURLProtocol.status = 403
    StubURLProtocol.headers = [:]
    let c7 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
    t.equal(await c7.fetch(), .failure(.forbidden))

    StubURLProtocol.status = 200
    StubURLProtocol.body = Data("oversized".utf8)
    let c8 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session(),
                         maxResponseBytes: 3)
    t.equal(await c8.fetch(), .failure(.responseTooLarge))
}

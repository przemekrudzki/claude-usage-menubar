import Foundation
import ClaudeUsageCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
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
    StubURLProtocol.body = Data(#"{"limits":[{"kind":"session","group":"session","percent":40,"severity":"normal","resets_at":"2026-07-07T19:40:00+00:00"},{"kind":"weekly_all","group":"weekly","percent":20,"severity":"normal","resets_at":"2026-07-11T08:00:00+00:00"}],"extra_usage":{"is_enabled":false}}"#.utf8)
    let c3 = UsageClient(tokenProvider: { "tok" }, session: StubURLProtocol.session())
    if case .success(let snap) = await c3.fetch() {
        t.equal(snap.session.percent, 40)
        t.equal(snap.weekly.percent, 20)
    } else {
        t.expect(false, "expected success")
    }
}

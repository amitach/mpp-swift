import Foundation
import HTTPTypes
import MPPServer
import Testing
@testable import MPPProxy

// Cache-header pins (audit):
// - DISC-CACHE: the discovery document is publicly cacheable (it carries no secret).
// - PROXY-CACHE: a paid route's response is never publicly cacheable -- a permissive upstream
//   `Cache-Control` is downgraded to at least `private` by the §11.10 floor, so a paid answer is
//   not stored in a shared cache and served to a non-paying client.
@Suite("Proxy cache headers")
struct ProxyCacheTests {
    @Test("GET /openapi.json is publicly cacheable (DISC-CACHE)")
    func discoveryDocIsCacheable() async throws {
        let proxy = try standardProxy(transport: RecordingTransport())
        let (response, _) = await proxy.handle(
            makeRequest(.get, "/openapi.json"), body: Data(), now: proxyNow
        )
        #expect(response.status.code == 200)
        #expect(response.headerFields[.cacheControl] == "public, max-age=300")
    }

    @Test("a permissive upstream Cache-Control is downgraded on a paid route (PROXY-CACHE)")
    func paidRouteDowngradesUpstreamCache() async throws {
        var upstream = HTTPResponse(status: .ok)
        upstream.headerFields[.cacheControl] = "public, max-age=3600"
        let transport = RecordingTransport((upstream, Data("UPSTREAM".utf8)))
        let proxy = try standardProxy(transport: transport)
        let header = try proxyCredentialHeader()
        let (response, _) = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions", authorization: header),
            body: Data(), now: proxyNow
        )
        #expect(response.status.code == 200)
        // The §11.10 floor on a paid response overrides the upstream's `public`.
        #expect(response.headerFields[.cacheControl] == "private")
    }
}

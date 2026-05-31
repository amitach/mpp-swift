import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPDiscovery
import MPPServer
import Testing
@testable import MPPProxy

@Suite("MPPProxy: discovery, routing, forwarding")
struct MPPProxyRoutingTests {
    // MARK: Discovery

    @Test("GET /openapi.json returns a validatable document advertising paid + free routes")
    func openAPIDiscovery() async throws {
        let proxy = try standardProxy(transport: RecordingTransport())
        let (response, body) = await proxy.handle(
            makeRequest(.get, "/openapi.json"),
            body: Data(),
            now: proxyNow
        )
        #expect(response.status.code == 200)
        #expect(response.headerFields[.contentType] == "application/json")
        #expect(DiscoveryValidator.validate(body).isEmpty)

        let doc = try JSONDecoder().decode(DiscoveryDocument.self, from: body)
        #expect(doc.paths["/openai/v1/chat/completions"]?[.post]?.paymentInfo != nil)
        #expect(doc.paths["/openai/v1/models"]?[.get]?.paymentInfo == nil)
        #expect(doc.serviceInfo?.docs?.llms == "/llms.txt")
    }

    @Test("GET /openapi.json prefixes every advertised path with the basePath")
    func openAPIRespectsBasePath() async throws {
        let proxy = try standardProxy(transport: RecordingTransport(), basePath: "/api/proxy")
        let (response, body) = await proxy.handle(
            makeRequest(.get, "/api/proxy/openapi.json"), body: Data(), now: proxyNow
        )
        #expect(response.status.code == 200)
        let doc = try JSONDecoder().decode(DiscoveryDocument.self, from: body)
        #expect(doc.paths["/api/proxy/openai/v1/models"]?[.get] != nil)
        #expect(doc.serviceInfo?.docs?.llms == "/api/proxy/llms.txt")
    }

    @Test("GET /llms.txt returns text linked to the OpenAPI discovery document")
    func llmsTxt() async throws {
        let proxy = try standardProxy(transport: RecordingTransport())
        let (response, body) = await proxy.handle(
            makeRequest(.get, "/llms.txt"),
            body: Data(),
            now: proxyNow
        )
        #expect(response.status.code == 200)
        #expect(response.headerFields[.contentType] == "text/plain; charset=utf-8")
        let text = bodyString(body)
        #expect(text?.contains("openai") == true)
        #expect(text?.contains("/openapi.json") == true)
    }

    // MARK: Routing 404s

    @Test("an unknown service, an unmatched route, and the empty path each return 404")
    func notFoundCases() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        for request in [
            makeRequest(.get, "/unknown/x"),
            makeRequest(.post, "/openai/v1/nope"),
            makeRequest(.get, "/"),
        ] {
            let (response, _) = await proxy.handle(request, body: Data(), now: proxyNow)
            #expect(response.status.code == 404)
        }
        await #expect(transport.callCount == 0)
    }

    @Test("a POST to a path registered only for GET does not fall back to the free GET route")
    func noMethodFallback() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        let (response, _) = await proxy.handle(
            makeRequest(.post, "/openai/v1/models"),
            body: Data(),
            now: proxyNow
        )
        #expect(response.status.code == 404)
        await #expect(transport.callCount == 0)
    }

    // MARK: Free passthrough + forwarding

    @Test("a free route forwards to the origin and relays the upstream body")
    func freePassthrough() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        let (response, body) = await proxy.handle(
            makeRequest(.get, "/openai/v1/models"),
            body: Data(),
            now: proxyNow
        )
        #expect(response.status.code == 200)
        #expect(bodyString(body) == "UPSTREAM")
        await #expect(transport.lastRequest?.path == "/v1/models")
    }

    @Test("the origin's base path is joined with the request path")
    func joinsBasePaths() async throws {
        let transport = RecordingTransport()
        let service = try ProxyService(
            id: "svc", baseURL: proxyURL("https://api.example.com/v1"),
            routes: [
                ProxyRoute(method: .get, pattern: RoutePattern("/models"), endpoint: .free),
            ]
        )
        let proxy = try MPPProxy(
            services: [service], info: .init(title: "P", version: "1"), transport: transport
        )
        _ = await proxy.handle(makeRequest(.get, "/svc/models"), body: Data(), now: proxyNow)
        await #expect(transport.lastRequest?.path == "/v1/models")
    }

    @Test("query parameters are forwarded to the origin")
    func forwardsQuery() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        _ = await proxy.handle(
            makeRequest(.get, "/openai/v1/models?limit=10&order=desc"), body: Data(), now: proxyNow
        )
        await #expect(transport.lastRequest?.path == "/v1/models?limit=10&order=desc")
    }

    @Test("a duplicate service id is deduplicated (first wins) for routing and discovery alike")
    func duplicateServiceIDDeduped() async throws {
        let first = try ProxyService(
            id: "svc", baseURL: proxyURL("https://first.example"),
            routes: [ProxyRoute(method: .get, pattern: RoutePattern("/a"), endpoint: .free)]
        )
        let second = try ProxyService(
            id: "svc", baseURL: proxyURL("https://second.example"),
            routes: [ProxyRoute(method: .get, pattern: RoutePattern("/b"), endpoint: .free)]
        )
        let transport = RecordingTransport()
        let proxy = try MPPProxy(
            services: [first, second], info: .init(title: "P", version: "1"), transport: transport
        )
        // Routing uses the first service: /svc/a forwards (to first.example), /svc/b 404s.
        _ = await proxy.handle(makeRequest(.get, "/svc/a"), body: Data(), now: proxyNow)
        await #expect(transport.lastRequest?.authority == "first.example")
        let (notFound, _) = await proxy.handle(
            makeRequest(.get, "/svc/b"),
            body: Data(),
            now: proxyNow
        )
        #expect(notFound.status.code == 404)
        // Discovery advertises the same (first) set: /svc/a present, /svc/b absent.
        let (_, body) = await proxy.handle(
            makeRequest(.get, "/openapi.json"),
            body: Data(),
            now: proxyNow
        )
        let doc = try JSONDecoder().decode(DiscoveryDocument.self, from: body)
        #expect(doc.paths["/svc/a"] != nil)
        #expect(doc.paths["/svc/b"] == nil)
    }

    @Test("a transport failure surfaces as 502 Bad Gateway")
    func badGateway() async throws {
        let proxy = try standardProxy(transport: ThrowingTransport())
        let (response, _) = await proxy.handle(
            makeRequest(.get, "/openai/v1/models"),
            body: Data(),
            now: proxyNow
        )
        #expect(response.status.code == 502)
    }
}

@Suite("MPPProxy: gating, header hygiene, receipts")
struct MPPProxyGatingTests {
    @Test("the request body is forwarded unchanged to the origin")
    func forwardsBody() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        let header = try proxyCredentialHeader()
        let payload = Data("{\"prompt\":\"hi\"}".utf8)
        _ = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions", authorization: header),
            body: payload, now: proxyNow
        )
        await #expect(transport.lastBody == payload)
    }

    @Test("the client's Payment credential is stripped before the request is forwarded")
    func stripsClientAuthorization() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        let header = try proxyCredentialHeader()
        _ = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions", authorization: header),
            body: Data(), now: proxyNow
        )
        await #expect(transport.lastRequest?.headerFields[.authorization] == nil)
    }

    @Test("safe headers survive forwarding while cookie, Host, and hop-by-hop are dropped")
    func preservesSafeHeadersDropsUnsafe() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        let trace = try #require(HTTPField.Name("X-Trace"))
        let host = try #require(HTTPField.Name("Host"))
        _ = await proxy.handle(
            makeRequest(
                .get, "/openai/v1/models",
                headers: [
                    .accept: "application/json", .cookie: "s=1", trace: "abc",
                    host: "client.example", .connection: "keep-alive",
                ]
            ),
            body: Data(), now: proxyNow
        )
        await #expect(transport.lastRequest?.headerFields[.accept] == "application/json")
        await #expect(transport.lastRequest?.headerFields[trace] == "abc")
        await #expect(transport.lastRequest?.headerFields[.cookie] == nil)
        // Host is dropped so the upstream sees only the authority the proxy targets; a hop-by-hop
        // header (Connection) must not be relayed onto the upstream connection (RFC 9110 §7.6.1).
        await #expect(transport.lastRequest?.headerFields[host] == nil)
        await #expect(transport.lastRequest?.headerFields[.connection] == nil)
    }

    @Test("a bearer-configured service injects Authorization upstream, even on a free route")
    func injectsBearer() async throws {
        let transport = RecordingTransport()
        let service = try ProxyService(
            id: "svc", baseURL: proxyURL("https://api.example.com"),
            routes: [
                ProxyRoute(method: .get, pattern: RoutePattern("/models"), endpoint: .free),
            ],
            bearer: "sk-secret"
        )
        let proxy = try MPPProxy(
            services: [service],
            info: .init(title: "P", version: "1"),
            transport: transport
        )
        _ = await proxy.handle(makeRequest(.get, "/svc/models"), body: Data(), now: proxyNow)
        await #expect(transport.lastRequest?.headerFields[.authorization] == "Bearer sk-secret")
    }

    @Test("a headers-configured service injects custom headers upstream")
    func injectsCustomHeaders() async throws {
        let transport = RecordingTransport()
        let service = try ProxyService(
            id: "svc", baseURL: proxyURL("https://api.example.com"),
            routes: [
                ProxyRoute(method: .get, pattern: RoutePattern("/models"), endpoint: .free),
            ],
            headers: ["X-Api-Key": "k123"]
        )
        let proxy = try MPPProxy(
            services: [service],
            info: .init(title: "P", version: "1"),
            transport: transport
        )
        _ = await proxy.handle(makeRequest(.get, "/svc/models"), body: Data(), now: proxyNow)
        let key = try #require(HTTPField.Name("X-Api-Key"))
        await #expect(transport.lastRequest?.headerFields[key] == "k123")
    }

    @Test("Set-Cookie and hop-by-hop are stripped from the upstream response; safe headers survive")
    func scrubsResponseUnsafeHeaders() async throws {
        var upstream = HTTPResponse(status: .ok)
        upstream.headerFields[.setCookie] = "session=evil; Domain=.proxy.example"
        upstream.headerFields[.connection] = "close"
        let safe = try #require(HTTPField.Name("X-Upstream"))
        upstream.headerFields[safe] = "kept"
        let transport = RecordingTransport((upstream, Data("ok".utf8)))
        let proxy = try standardProxy(transport: transport)
        let (response, _) = await proxy.handle(
            makeRequest(.get, "/openai/v1/models"),
            body: Data(),
            now: proxyNow
        )
        #expect(response.headerFields[.setCookie] == nil)
        // Hop-by-hop headers govern the upstream connection and must not reach the client (§7.6.1).
        #expect(response.headerFields[.connection] == nil)
        #expect(response.headerFields[safe] == "kept")
    }

    @Test("a paid route with no credential returns 402 and does not reach the origin")
    func paidNoCredentialIs402() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        let (response, _) = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions"), body: Data(), now: proxyNow
        )
        #expect(response.status.code == 402)
        #expect(response.headerFields[.wwwAuthenticate] != nil)
        await #expect(transport.callCount == 0)
    }

    @Test("a paid route with a valid credential verifies and forwards to the origin")
    func paidValidCredentialForwards() async throws {
        let transport = RecordingTransport()
        let proxy = try standardProxy(transport: transport)
        let header = try proxyCredentialHeader()
        let (response, body) = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions", authorization: header),
            body: Data(), now: proxyNow
        )
        #expect(response.status.code == 200)
        #expect(bodyString(body) == "UPSTREAM")
        await #expect(transport.callCount == 1)
    }

    @Test("the gate relays an upstream error status faithfully on a paid route")
    func relaysUpstreamError() async throws {
        let transport = RecordingTransport((
            HTTPResponse(status: .internalServerError),
            Data("boom".utf8)
        ))
        let proxy = try standardProxy(transport: transport)
        let header = try proxyCredentialHeader()
        let (response, body) = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions", authorization: header),
            body: Data(), now: proxyNow
        )
        #expect(response.status.code == 500)
        #expect(bodyString(body) == "boom")
    }

    @Test("the gate emits a challenge-issued event when unpaid and a verified event when paid")
    func emitsServerEvents() async throws {
        let box = EventBox()
        let proxy = try standardProxy(transport: RecordingTransport(), onEvent: box.add)
        _ = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions"),
            body: Data(),
            now: proxyNow
        )
        let header = try proxyCredentialHeader()
        _ = await proxy.handle(
            makeRequest(.post, "/openai/v1/chat/completions", authorization: header),
            body: Data(), now: proxyNow
        )
        #expect(box.events.contains { if case .challengeIssued = $0 { true } else { false } })
        #expect(box.events.contains { if case .paymentVerified = $0 { true } else { false } })
    }

    @Test("a credential minted for one paid route is rejected on another (per-route binding)")
    func crossRouteReplayRejected() async throws {
        let transport = RecordingTransport()
        let gateA = try makeProxyMiddleware(binding: proxyBinding(realm: "a.example"))
        let gateB = try makeProxyMiddleware(binding: proxyBinding(realm: "b.example"))
        let service = try ProxyService(
            id: "svc", baseURL: proxyURL("https://api.example.com"),
            routes: [
                ProxyRoute(
                    method: .post, pattern: RoutePattern("/a"),
                    endpoint: .paid(gateA, payment: samplePayment())
                ),
                ProxyRoute(
                    method: .post, pattern: RoutePattern("/b"),
                    endpoint: .paid(gateB, payment: samplePayment())
                ),
            ]
        )
        let proxy = try MPPProxy(
            services: [service],
            info: .init(title: "P", version: "1"),
            transport: transport
        )
        let headerForA = try proxyCredentialHeader(binding: proxyBinding(realm: "a.example"))
        let (response, _) = await proxy.handle(
            makeRequest(.post, "/svc/b", authorization: headerForA), body: Data(), now: proxyNow
        )
        #expect(response.status.code == 402)
        await #expect(transport.callCount == 0)
    }
}

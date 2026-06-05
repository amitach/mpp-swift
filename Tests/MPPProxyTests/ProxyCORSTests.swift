import Foundation
import HTTPTypes
import MPPServer
import Testing
@testable import MPPProxy

// CORS for the discovery surfaces (§6.3 SHOULD, opt-in): with no policy the responses carry no
// access-control headers (peer parity); a policy adds them to GET /openapi.json + /llms.txt and
// answers their OPTIONS preflight, and never touches proxied routes.
@Suite("Proxy discovery CORS")
struct ProxyCORSTests {
    private let acao = HTTPField.Name.accessControlAllowOrigin
    private let acam = HTTPField.Name.accessControlAllowMethods

    @Test("no policy emits no CORS header on the discovery docs (peer parity, the default)")
    func noPolicyNoHeader() async throws {
        let proxy = try standardProxy(transport: RecordingTransport())
        for path in ["/openapi.json", "/llms.txt"] {
            let (response, _) = await proxy.handle(
                makeRequest(.get, path),
                body: Data(),
                now: proxyNow
            )
            #expect(response.status.code == 200)
            #expect(response.headerFields[acao] == nil)
        }
    }

    @Test("allowAnyOrigin adds Access-Control-Allow-Origin: * to both discovery docs")
    func wildcardOnGet() async throws {
        let proxy = try standardProxy(transport: RecordingTransport(), cors: .allowAnyOrigin)
        for path in ["/openapi.json", "/llms.txt"] {
            let (response, _) = await proxy.handle(
                makeRequest(.get, path),
                body: Data(),
                now: proxyNow
            )
            #expect(response.headerFields[acao] == "*")
            // A wildcard origin is not origin-specific, so no Vary: Origin.
            #expect(response.headerFields[.vary] == nil)
        }
    }

    @Test("a specific origin is echoed and sets Vary: Origin so a shared cache keys by origin")
    func specificOriginVaries() async throws {
        let origin = "https://app.example.com"
        let proxy = try standardProxy(
            transport: RecordingTransport(), cors: CORSPolicy(allowOrigin: origin)
        )
        let (response, _) = await proxy.handle(
            makeRequest(.get, "/openapi.json"), body: Data(), now: proxyNow
        )
        #expect(response.headerFields[acao] == origin)
        #expect(response.headerFields[.vary] == "Origin")
    }

    @Test("an OPTIONS preflight to a discovery path returns 204 with the access-control headers")
    func optionsPreflight() async throws {
        let proxy = try standardProxy(transport: RecordingTransport(), cors: .allowAnyOrigin)
        let (response, body) = await proxy.handle(
            makeRequest(.options, "/openapi.json"), body: Data(), now: proxyNow
        )
        #expect(response.status.code == 204)
        #expect(body.isEmpty)
        #expect(response.headerFields[acao] == "*")
        #expect(response.headerFields[acam] == "GET, OPTIONS")
        #expect(response.headerFields[.accessControlMaxAge] == "600")
    }

    @Test("a preflight echoes Access-Control-Request-Headers into Allow-Headers (Fetch spec)")
    func preflightEchoesRequestedHeaders() async throws {
        let proxy = try standardProxy(transport: RecordingTransport(), cors: .allowAnyOrigin)
        let request = makeRequest(
            .options, "/openapi.json",
            headers: [.accessControlRequestHeaders: "X-Custom, Authorization"]
        )
        let (response, _) = await proxy.handle(request, body: Data(), now: proxyNow)
        #expect(response.status.code == 204)
        #expect(response.headerFields[.accessControlAllowHeaders] == "X-Custom, Authorization")
    }

    @Test("a preflight with no requested headers omits Allow-Headers")
    func preflightWithoutRequestedHeaders() async throws {
        let proxy = try standardProxy(transport: RecordingTransport(), cors: .allowAnyOrigin)
        let (response, _) = await proxy.handle(
            makeRequest(.options, "/llms.txt"), body: Data(), now: proxyNow
        )
        #expect(response.headerFields[.accessControlAllowHeaders] == nil)
    }

    @Test("an OPTIONS preflight without a configured policy is not intercepted (404)")
    func optionsWithoutPolicy() async throws {
        let proxy = try standardProxy(transport: RecordingTransport())
        let (response, _) = await proxy.handle(
            makeRequest(.options, "/openapi.json"), body: Data(), now: proxyNow
        )
        // No CORS opt-in, so OPTIONS falls through to routing and finds no service named
        // "openapi.json".
        #expect(response.status.code == 404)
    }

    @Test("the CORS policy never adds headers to a proxied (non-discovery) route")
    func noCORSOnProxiedRoute() async throws {
        let proxy = try standardProxy(
            transport: RecordingTransport((HTTPResponse(status: .ok), Data("UPSTREAM".utf8))),
            cors: .allowAnyOrigin
        )
        // A free GET route forwards the origin's response untouched -- CORS for it is the origin's
        // concern, not the proxy's.
        let (response, _) = await proxy.handle(
            makeRequest(.get, "/openai/v1/models"), body: Data(), now: proxyNow
        )
        #expect(response.status.code == 200)
        #expect(response.headerFields[acao] == nil)
    }
}

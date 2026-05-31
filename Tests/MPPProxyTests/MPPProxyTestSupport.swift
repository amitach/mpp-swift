import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPDiscovery
import MPPServer
import Testing
@testable import MPPProxy

// Shared fixtures for MPPProxyTests: a fixed secret/clock, a per-route gate built on the same
// minter/verifier seam the server tests use (protocol-only, so no payment rail is needed: a valid
// server-signed credential proceeds), a recording transport that captures the forwarded upstream
// request, and request/discovery builders. Internal (target-scoped).

let proxySecret = Data("test-secret-key-12345".utf8)
let proxyNow = Date(timeIntervalSince1970: 1_767_312_000)

func proxyBinding(
    realm: String = "api.example.com", intent: IntentName = .charge
) throws -> RouteBinding {
    try RouteBinding(realm: realm, method: MethodName("tempo"), intent: intent)
}

/// A per-route gate sharing one secret + replay store, protocol-only (no payment methods).
func makeProxyMiddleware(
    binding: RouteBinding? = nil,
    store: any ReplayStore = InMemoryReplayStore(),
    onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
) throws -> MPPServerMiddleware {
    let signer = ChallengeSigner(secret: proxySecret)
    return try MPPServerMiddleware(
        minter: ChallengeMinter(signer: signer),
        verifier: PaymentVerifier(signer: signer, replayStore: store, methods: []),
        binding: binding ?? proxyBinding(),
        request: EncodedJSON("e30"),
        expiresIn: 300,
        onEvent: onEvent
    )
}

/// An `Authorization: Payment` header whose challenge is minted for `binding`.
func proxyCredentialHeader(binding: RouteBinding? = nil) throws -> String {
    let signer = ChallengeSigner(secret: proxySecret)
    let route = try binding ?? proxyBinding()
    let challenge = ChallengeMinter(signer: signer).mint(
        binding: route, request: EncodedJSON("e30"), digest: nil,
        expires: Expires(date: proxyNow.addingTimeInterval(300))
    )
    return try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
}

/// A `PaymentInfo` for a paid route's discovery advertisement (dynamic price).
func samplePayment() throws -> PaymentInfo {
    try #require(PaymentInfo(offers: [
        PaymentOffer(amount: .dynamic, currency: "USD", intent: "charge", method: "tempo"),
    ]))
}

/// Parses a URL literal, failing the test if it is malformed.
func proxyURL(_ string: String) throws -> URL {
    try #require(URL(string: string))
}

/// Decodes a response body as UTF-8 (nil if it is not valid UTF-8).
func bodyString(_ data: Data) -> String? {
    String(bytes: data, encoding: .utf8)
}

/// The standard two-route service used by most engine tests: a paid POST and a free GET on
/// `openai`.
func standardProxy(
    transport: any MPPHTTPTransport,
    basePath: String? = nil,
    onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
) throws -> MPPProxy {
    let gate = try makeProxyMiddleware(onEvent: onEvent)
    let service = try ProxyService(
        id: "openai",
        baseURL: proxyURL("https://api.openai.com"),
        routes: [
            ProxyRoute(
                method: .post, pattern: RoutePattern("/v1/chat/completions"),
                endpoint: .paid(gate, payment: samplePayment()), summary: "Chat",
                requestBody: .object(["description": .string("Chat completion request")])
            ),
            ProxyRoute(method: .get, pattern: RoutePattern("/v1/models"), endpoint: .free),
        ]
    )
    return try MPPProxy(
        services: [service], info: .init(title: "Proxy", version: "1"),
        basePath: basePath, transport: transport
    )
}

/// An ``MPPHTTPTransport`` that records the forwarded upstream request/body and returns a canned
/// response.
actor RecordingTransport: MPPHTTPTransport {
    private(set) var lastRequest: HTTPRequest?
    private(set) var lastBody: Data?
    private(set) var callCount = 0
    var response: (HTTPResponse, Data)

    init(_ response: (HTTPResponse, Data) = (HTTPResponse(status: .ok), Data("UPSTREAM".utf8))) {
        self.response = response
    }

    func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        lastRequest = request
        lastBody = body
        callCount += 1
        return response
    }
}

/// A transport that always fails, to drive the proxy's 502 path.
struct ThrowingTransport: MPPHTTPTransport {
    struct Boom: Error {}
    func send(_: HTTPRequest, body _: Data) async throws -> (HTTPResponse, Data) {
        throw Boom()
    }
}

/// A thread-safe sink for the gate's `ServerEvent`s (the gate's `onEvent` is synchronous).
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ServerEvent] = []

    func add(_ event: ServerEvent) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(event)
    }

    var events: [ServerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func makeRequest(
    _ method: HTTPRequest.Method,
    _ path: String,
    authorization: String? = nil,
    headers: [HTTPField.Name: String] = [:]
) -> HTTPRequest {
    var fields = HTTPFields()
    if let authorization { fields[.authorization] = authorization }
    for (name, value) in headers {
        fields[name] = value
    }
    return HTTPRequest(
        method: method, scheme: "https", authority: "proxy.example",
        path: path, headerFields: fields
    )
}

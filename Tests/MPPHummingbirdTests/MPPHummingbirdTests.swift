import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MPPClient
import MPPCore
import MPPDiscovery
import MPPProxy
import MPPServer
import NIOCore
import Testing
@testable import MPPHummingbird

// The binding's job is faithful request/response bridging (Hummingbird Request -> the engine's
// (HTTPRequest, Data) -> Response); the engine's own logic is covered by MPPProxyTests. These tests
// run a real Hummingbird server (.live) for the proxy responder and the router for the gated
// responder, with a stub upstream so they stay hermetic. Each test guards on the macOS 14 / iOS 17
// availability Hummingbird 2's runtime requires (swift-testing forbids @available on the suite).

@Suite("MPPHummingbird binding")
struct MPPHummingbirdTests {
    private let clock = Date(timeIntervalSince1970: 1_767_312_000)
    private let secret = Data("test-secret-key-12345".utf8)

    private func binding() throws -> RouteBinding {
        try RouteBinding(realm: "api.example.com", method: MethodName("tempo"), intent: .charge)
    }

    private func middleware() throws -> MPPServerMiddleware {
        let signer = ChallengeSigner(secret: secret)
        return try MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            verifier: PaymentVerifier(
                signer: signer,
                replayStore: InMemoryReplayStore(),
                methods: []
            ),
            binding: binding(), request: EncodedJSON("e30"), expiresIn: 300
        )
    }

    private func credentialHeader() throws -> String {
        let signer = ChallengeSigner(secret: secret)
        let challenge = try ChallengeMinter(signer: signer).mint(
            binding: binding(), request: EncodedJSON("e30"), digest: nil,
            expires: Expires(date: clock.addingTimeInterval(300))
        )
        return try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
    }

    private func proxy(transport: any MPPHTTPTransport) throws -> MPPProxy {
        let service = try ProxyService(
            id: "openai", baseURL: #require(URL(string: "https://api.openai.com")),
            routes: [
                ProxyRoute(
                    method: .post, pattern: RoutePattern("/v1/chat/completions"),
                    endpoint: .paid(middleware(), payment: payment())
                ),
                ProxyRoute(method: .get, pattern: RoutePattern("/v1/models"), endpoint: .free),
            ]
        )
        return try MPPProxy(
            services: [service],
            info: .init(title: "Proxy", version: "1"),
            transport: transport
        )
    }

    private func payment() throws -> PaymentInfo {
        try #require(PaymentInfo(offers: [
            PaymentOffer(amount: .dynamic, currency: "USD", intent: "charge", method: "tempo"),
        ]))
    }

    @Test("a live server serves /llms.txt and forwards a free route through the bridge")
    func liveProxyFreeAndDiscovery() async throws {
        guard #available(macOS 14, iOS 17, tvOS 17, visionOS 1, *) else { return }
        let app = try MPPHummingbird.application(
            for: proxy(transport: StubTransport()),
            port: 0,
            now: { clock }
        )
        try await app.test(.live) { client in
            let llms = try await client.execute(uri: "/llms.txt", method: .get)
            #expect(llms.status == .ok)
            #expect(String(buffer: llms.body).contains("openai"))

            let free = try await client.execute(uri: "/openai/v1/models", method: .get)
            #expect(free.status == .ok)
            #expect(String(buffer: free.body) == "UPSTREAM")
        }
    }

    @Test("a live server returns 402 unpaid and forwards the body when paid")
    func liveProxyGate() async throws {
        guard #available(macOS 14, iOS 17, tvOS 17, visionOS 1, *) else { return }
        let transport = StubTransport()
        let app = try MPPHummingbird.application(
            for: proxy(transport: transport),
            port: 0,
            now: { clock }
        )
        try await app.test(.live) { client in
            let unpaid = try await client.execute(uri: "/openai/v1/chat/completions", method: .post)
            #expect(unpaid.status.code == 402)

            let paid = try await client.execute(
                uri: "/openai/v1/chat/completions", method: .post,
                headers: [.authorization: credentialHeader()],
                body: ByteBuffer(string: "{\"prompt\":\"hi\"}")
            )
            #expect(paid.status == .ok)
            #expect(String(buffer: paid.body) == "UPSTREAM")
        }
        await #expect(transport.lastBody == Data("{\"prompt\":\"hi\"}".utf8))
    }

    @Test("a gated terminal route returns 402 unpaid and runs the handler when paid")
    func gatedTerminalRoute() async throws {
        guard #available(macOS 14, iOS 17, tvOS 17, visionOS 1, *) else { return }
        let router = Router()
        let responder = try GatedResponder<BasicRequestContext>(
            gate: middleware(),
            now: { clock },
            handler: { _, _ in (HTTPResponse(status: .ok), Data("PROOF-OK".utf8)) }
        )
        router.post("proof") { request, context in
            try await responder.respond(to: request, context: context)
        }
        let app = Application(router: router)
        try await app.test(.router) { client in
            let unpaid = try await client.execute(uri: "/proof", method: .post)
            #expect(unpaid.status.code == 402)

            let paid = try await client.execute(
                uri: "/proof", method: .post, headers: [.authorization: credentialHeader()]
            )
            #expect(paid.status == .ok)
            #expect(String(buffer: paid.body) == "PROOF-OK")
        }
    }
}

/// A stub upstream transport that records the forwarded body and returns a fixed response.
actor StubTransport: MPPHTTPTransport {
    private(set) var lastBody: Data?
    func send(_: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        lastBody = body
        return (HTTPResponse(status: .ok), Data("UPSTREAM".utf8))
    }
}

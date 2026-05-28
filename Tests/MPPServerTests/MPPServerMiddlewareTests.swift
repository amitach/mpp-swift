import Foundation
import HTTPTypes
import MPPCore
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §5.1 (mint), §11.10 (no-store on 402, private
// on the paid response). The 413 body cap is an MPP-swift DoS guard, not a spec
// requirement. The middleware ties ChallengeMinter + PaymentVerifier together.
@Suite("MPPServerMiddleware")
struct MPPServerMiddlewareTests {
    private let secret = Data("test-secret-key-12345".utf8)
    private let now = Date(timeIntervalSince1970: 1_767_312_000) // 2026-01-02T00:00:00Z

    private func makeBinding() throws -> RouteBinding {
        try RouteBinding(realm: "api.example.com", method: MethodName("tempo"), intent: .charge)
    }

    /// A middleware whose minter and verifier share one secret and replay store.
    private func makeMiddleware(
        maxBodyBytes: Int = 10 * 1024 * 1024,
        store: any ReplayStore = InMemoryReplayStore(),
        onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
    ) throws -> MPPServerMiddleware {
        let signer = ChallengeSigner(secret: secret)
        return try MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            verifier: PaymentVerifier(signer: signer, replayStore: store),
            binding: makeBinding(),
            request: EncodedJSON("e30"),
            expiresIn: 300,
            maxBodyBytes: maxBodyBytes,
            onEvent: onEvent
        )
    }

    /// An `Authorization: Payment` value whose challenge is minted for the route.
    private func paidHeader() throws -> String {
        let challenge = ChallengeMinter(signer: ChallengeSigner(secret: secret))
            .mint(binding: try makeBinding(), request: EncodedJSON("e30"))
        return try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
    }

    private func makeRequest(authorization: String? = nil) -> HTTPRequest {
        var fields = HTTPFields()
        if let authorization { fields[.authorization] = authorization }
        return HTTPRequest(
            method: .post,
            scheme: "https",
            authority: "api.example.com",
            path: "/r",
            headerFields: fields
        )
    }

    /// Collects events emitted during a request (sink is synchronous).
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ServerEvent] = []
        func add(_ event: ServerEvent) { lock.lock(); stored.append(event); lock.unlock() }
        var events: [ServerEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // Matchers, so assertions stay one short `#expect` line.
    private func challengeOf(
        _ decision: MPPServerMiddleware.Decision
    ) -> (Challenge, ProblemDetails)? {
        if case let .challenge(challenge, problem) = decision { return (challenge, problem) }
        return nil
    }

    private func isProceed(_ decision: MPPServerMiddleware.Decision) -> Bool {
        if case .proceed = decision { return true }
        return false
    }

    private func isTooLarge(_ decision: MPPServerMiddleware.Decision) -> Bool {
        if case .payloadTooLarge = decision { return true }
        return false
    }

    private func lastEventName(_ box: EventBox) -> String? {
        switch box.events.last {
        case .challengeIssued: return "challengeIssued"
        case .paymentVerified: return "paymentVerified"
        case .paymentRejected: return "paymentRejected"
        case nil: return nil
        }
    }

    // MARK: - evaluate (pure core)

    @Test("an over-large body is rejected before any payment work")
    func bodyCap() async throws {
        let middleware = try makeMiddleware(maxBodyBytes: 16)
        let decision = await middleware.evaluate(
            authorization: try paidHeader(), body: Data(count: 17), now: now
        )
        #expect(isTooLarge(decision))
    }

    @Test("a request with no credential mints a fresh challenge")
    func missingCredentialMintsChallenge() async throws {
        let box = EventBox()
        let middleware = try makeMiddleware(onEvent: box.add)
        let decision = await middleware.evaluate(authorization: nil, body: Data(), now: now)
        let (challenge, problem) = try #require(challengeOf(decision))
        #expect(try makeBinding().matches(challenge))
        #expect(problem.status == 402)
        #expect(problem.type == "https://paymentauth.org/problems/payment-required")
        #expect(problem.extensions["challengeId"] == .string(challenge.id))
        #expect(lastEventName(box) == "challengeIssued")
    }

    @Test("a valid credential proceeds with a verified token")
    func validCredentialProceeds() async throws {
        let box = EventBox()
        let middleware = try makeMiddleware(onEvent: box.add)
        let decision = await middleware.evaluate(
            authorization: try paidHeader(), body: Data(), now: now
        )
        #expect(isProceed(decision))
        #expect(lastEventName(box) == "paymentVerified")
    }

    @Test("a malformed credential is rejected and offered a fresh challenge")
    func malformedCredentialRejected() async throws {
        let box = EventBox()
        let middleware = try makeMiddleware(onEvent: box.add)
        let decision = await middleware.evaluate(
            authorization: "Bearer not-a-payment", body: Data(), now: now
        )
        let (_, problem) = try #require(challengeOf(decision))
        #expect(problem.type == "https://paymentauth.org/problems/malformed-credential")
        #expect(lastEventName(box) == "paymentRejected")
    }

    @Test("a replayed credential is rejected on its second use")
    func replayRejected() async throws {
        let middleware = try makeMiddleware(store: InMemoryReplayStore())
        let header = try paidHeader()
        let first = await middleware.evaluate(authorization: header, body: Data(), now: now)
        #expect(isProceed(first))
        let second = await middleware.evaluate(authorization: header, body: Data(), now: now)
        let (_, problem) = try #require(challengeOf(second))
        #expect(problem.detail == "The challenge has already been used.")
    }

    // MARK: - handle (swift-http-types binding)

    @Test("a 402 carries WWW-Authenticate, no-store, and a problem+json body")
    func http402() async throws {
        let middleware = try makeMiddleware()
        var handlerRan = false
        let (response, body) = await middleware.handle(
            makeRequest(), body: Data(), now: now
        ) { _, _ in
            handlerRan = true
            return (HTTPResponse(status: .ok), Data())
        }
        #expect(response.status.code == 402)
        #expect(response.headerFields[.wwwAuthenticate]?.hasPrefix("Payment ") == true)
        #expect(response.headerFields[.cacheControl] == "no-store")
        #expect(response.headerFields[.contentType] == "application/problem+json")
        #expect(!body.isEmpty)
        #expect(!handlerRan) // the unpaid path never runs the handler
    }

    @Test("a 413 is returned for an over-large body without running the handler")
    func http413() async throws {
        let middleware = try makeMiddleware(maxBodyBytes: 16)
        var handlerRan = false
        let request = makeRequest(authorization: try paidHeader())
        let (response, _) = await middleware.handle(
            request, body: Data(count: 17), now: now
        ) { _, _ in
            handlerRan = true
            return (HTTPResponse(status: .ok), Data())
        }
        #expect(response.status.code == 413)
        #expect(response.headerFields[.cacheControl] == "no-store")
        #expect(!handlerRan)
    }

    @Test("a paid request runs the handler and decorates the 200 with Cache-Control: private")
    func http200Receipted() async throws {
        let middleware = try makeMiddleware()
        let request = makeRequest(authorization: try paidHeader())
        let (response, body) = await middleware.handle(
            request, body: Data(), now: now
        ) { _, verified in
            #expect(verified.credential.challenge.method.rawValue == "tempo")
            return (HTTPResponse(status: .ok), Data("ok".utf8))
        }
        #expect(response.status.code == 200)
        #expect(response.headerFields[.cacheControl] == "private")
        #expect(String(bytes: body, encoding: .utf8) == "ok")
    }
}

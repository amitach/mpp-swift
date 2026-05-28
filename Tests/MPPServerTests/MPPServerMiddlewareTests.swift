import Foundation
import HTTPTypes
import MPPCore
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §5.1 (mint), §11.10 (no-store on 402, private
// on the paid response). The 413 body cap is an MPP-swift DoS guard, not a spec
// requirement. The middleware ties ChallengeMinter + PaymentVerifier together.
// Shared fixtures at file scope (one home; keeps the suite body under the cap).
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
    try headerFor()
}

/// A credential header minted with overridable secret/binding/expiry/digest,
/// to drive each `PaymentVerifier.Rejection` through the middleware.
private func headerFor(
    signedWith customSecret: Data? = nil,
    binding customBinding: RouteBinding? = nil,
    expires: Expires? = nil,
    digest: String? = nil
) throws -> String {
    let signer = ChallengeSigner(secret: customSecret ?? secret)
    let route = try customBinding ?? makeBinding()
    let challenge = ChallengeMinter(signer: signer).mint(
        binding: route, request: EncodedJSON("e30"), digest: digest, expires: expires
    )
    return try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
}

/// Drives `header` through `evaluate` and returns the resulting 402 problem type.
private func rejectionProblemType(
    _ header: String, body: Data = Data()
) async throws -> String? {
    let decision = try await makeMiddleware().evaluate(
        authorization: header, body: body, now: now
    )
    return challengeOf(decision)?.1.type
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
    func add(_ event: ServerEvent) {
        lock.lock(); stored.append(event); lock.unlock()
    }

    var events: [ServerEvent] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
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

private func eventName(_ event: ServerEvent) -> String {
    switch event {
    case .challengeIssued: return "challengeIssued"
    case .paymentVerified: return "paymentVerified"
    case .paymentRejected: return "paymentRejected"
    }
}

private func lastEventName(_ box: EventBox) -> String? {
    box.events.last.map(eventName)
}

private func eventNames(_ box: EventBox) -> [String] {
    box.events.map(eventName)
}

@Suite("MPPServerMiddleware")
struct MPPServerMiddlewareTests {
    // MARK: - evaluate (pure core)

    @Test("an over-large body is rejected before any payment work")
    func bodyCap() async throws {
        let middleware = try makeMiddleware(maxBodyBytes: 16)
        let decision = try await middleware.evaluate(
            authorization: paidHeader(), body: Data(count: 17), now: now
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
        let decision = try await middleware.evaluate(
            authorization: paidHeader(), body: Data(), now: now
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
        #expect(eventNames(box) == ["paymentRejected", "challengeIssued"])
    }

    @Test("a replayed credential is rejected as invalid-challenge on its second use")
    func replayRejected() async throws {
        let middleware = try makeMiddleware(store: InMemoryReplayStore())
        let header = try paidHeader()
        let first = await middleware.evaluate(authorization: header, body: Data(), now: now)
        #expect(isProceed(first))
        let second = await middleware.evaluate(authorization: header, body: Data(), now: now)
        let (_, problem) = try #require(challengeOf(second))
        #expect(problem.type == "https://paymentauth.org/problems/invalid-challenge")
        #expect(problem.detail == "The challenge has already been used.")
    }

    @Test("each rejection maps to its spec problem type at the middleware layer")
    func rejectionProblemTypes() async throws {
        // A credential signed by a different secret fails the HMAC check.
        let forged = try headerFor(signedWith: Data("a-totally-different-secret-000".utf8))
        #expect(try await rejectionProblemType(forged)
            == "https://paymentauth.org/problems/invalid-challenge")

        // A validly signed credential minted for a different route (binding mismatch).
        let otherRoute = try RouteBinding(
            realm: "other.example.com", method: MethodName("tempo"), intent: .charge
        )
        let wrongRoute = try headerFor(binding: otherRoute)
        #expect(try await rejectionProblemType(wrongRoute)
            == "https://paymentauth.org/problems/verification-failed")

        // An expired challenge.
        let expired = try headerFor(expires: Expires("2020-01-01T00:00:00Z"))
        #expect(try await rejectionProblemType(expired)
            == "https://paymentauth.org/problems/payment-expired")

        // A challenge that binds a digest the request body does not satisfy.
        let badDigest = try headerFor(digest: "sha-256=:bm90LXRoZS1yaWdodC1ib2R5LWRpZ2VzdA==:")
        #expect(try await rejectionProblemType(badDigest, body: Data("hello".utf8))
            == "https://paymentauth.org/problems/verification-failed")
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
        let request = try makeRequest(authorization: paidHeader())
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

    @Test("a rejected credential answers 402 through handle with WWW-Authenticate + no-store")
    func http402OnRejection() async throws {
        let middleware = try makeMiddleware()
        let request = makeRequest(authorization: "Bearer not-a-payment")
        let (response, body) = await middleware.handle(request, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        #expect(response.status.code == 402)
        #expect(response.headerFields[.wwwAuthenticate]?.hasPrefix("Payment ") == true)
        #expect(response.headerFields[.cacheControl] == "no-store")
        #expect(response.headerFields[.contentType] == "application/problem+json")
        #expect(!body.isEmpty)
    }

    @Test("a body of exactly maxBodyBytes is allowed (the cap is inclusive)")
    func bodyCapBoundary() async throws {
        let middleware = try makeMiddleware(maxBodyBytes: 16)
        let decision = try await middleware.evaluate(
            authorization: paidHeader(), body: Data(count: 16), now: now
        )
        #expect(isProceed(decision))
    }

    @Test("a handler's own stricter Cache-Control survives (not downgraded to private)")
    func handlerCacheControlPreserved() async throws {
        let middleware = try makeMiddleware()
        let request = try makeRequest(authorization: paidHeader())
        let (response, _) = await middleware.handle(request, body: Data(), now: now) { _, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields[.cacheControl] = "no-store"
            return (response, Data())
        }
        #expect(response.status.code == 200)
        #expect(response.headerFields[.cacheControl] == "no-store")
    }

    @Test("a paid request runs the handler and decorates the 200 with Cache-Control: private")
    func http200Receipted() async throws {
        let middleware = try makeMiddleware()
        let request = try makeRequest(authorization: paidHeader())
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

    @Test("the 402's WWW-Authenticate round-trips into a credential that verifies through handle")
    func http402ChallengeRoundTrips() async throws {
        let middleware = try makeMiddleware()
        let (challengeResponse, _) = await middleware.handle(
            makeRequest(), body: Data(), now: now
        ) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        // Re-parse the emitted challenge, build a credential, and resubmit: proves
        // the header the server puts on the wire is exactly what the verifier accepts.
        let wwwAuth = try #require(challengeResponse.headerFields[.wwwAuthenticate])
        let challenge = try Challenge(headerValue: wwwAuth)
        let header = try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
        let (response, body) = await middleware.handle(
            makeRequest(authorization: header), body: Data(), now: now
        ) { _, _ in
            (HTTPResponse(status: .ok), Data("ok".utf8))
        }
        #expect(response.status.code == 200)
        #expect(String(bytes: body, encoding: .utf8) == "ok")
    }

    @Test("the emitted 402 body decodes to the expected RFC 9457 problem")
    func http402ProblemBodyDecodes() async throws {
        let middleware = try makeMiddleware()
        let (response, body) = await middleware.handle(
            makeRequest(), body: Data(), now: now
        ) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        let problem = try JSONDecoder().decode(ProblemDetails.self, from: body)
        #expect(problem.status == 402)
        #expect(problem.type == "https://paymentauth.org/problems/payment-required")
        let wwwAuth = try #require(response.headerFields[.wwwAuthenticate])
        let challenge = try Challenge(headerValue: wwwAuth)
        #expect(problem.extensions["challengeId"] == .string(challenge.id))
    }

    @Test("a rejection emits paymentRejected then challengeIssued for the retry challenge")
    func rejectionEmitsRejectedThenIssued() async throws {
        let box = EventBox()
        let middleware = try makeMiddleware(onEvent: box.add)
        _ = await middleware.evaluate(authorization: "Bearer not-a-payment", body: Data(), now: now)
        // The rejection is reported, then the retry challenge that was issued, so
        // challengeIssued counts every minted challenge (fresh and retry alike).
        #expect(eventNames(box) == ["paymentRejected", "challengeIssued"])
    }
}

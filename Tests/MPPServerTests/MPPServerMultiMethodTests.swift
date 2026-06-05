import Foundation
import HTTPTypes
import MPPCore
import Testing
@testable import MPPServer

// A route offering two methods (tempo or stripe), sharing one signer/verifier. The verifier is
// protocol-only (no settlement methods), so a structurally valid credential for either offer
// verifies on the protocol checks alone -- enough to exercise minting, the N WWW-Authenticate
// headers, and credential-to-offer routing.
@Suite("MPPServerMiddleware multi-method")
struct MPPServerMultiMethodTests {
    private let signer = ChallengeSigner(secret: secret)

    private func binding(_ method: String) throws -> RouteBinding {
        try RouteBinding(realm: "api.example.com", method: MethodName(method), intent: .charge)
    }

    private func multiMethodMiddleware() throws -> MPPServerMiddleware {
        try MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            verifier: PaymentVerifier(
                signer: signer,
                replayStore: InMemoryReplayStore(),
                methods: []
            ),
            offers: [
                MethodOffer(binding: binding("tempo"), request: EncodedJSON("e30")),
                MethodOffer(binding: binding("stripe"), request: EncodedJSON("e31")),
            ]
        )
    }

    private func credential(for challenge: Challenge) throws -> String {
        try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
    }

    @Test("evaluate offers one challenge per method, primary first, problem references the primary")
    func evaluateOffersAll() async throws {
        let middleware = try multiMethodMiddleware()
        let decision = await middleware.evaluate(authorization: nil, body: Data(), now: now)
        guard case let .challenge(challenges, problem) = decision else {
            Issue.record("expected a challenge"); return
        }
        #expect(challenges.count == 2)
        #expect(challenges.map(\.method.rawValue) == ["tempo", "stripe"])
        #expect(problem.extensions["challengeId"] == .string(challenges[0].id))
    }

    @Test("a credential-less 402 carries one WWW-Authenticate header per method")
    func emitsHeaderPerMethod() async throws {
        let middleware = try multiMethodMiddleware()
        let (response, _) = await middleware.handle(
            makeRequest(), body: Data(), now: now
        ) { _, _ in (HTTPResponse(status: .ok), Data()) }
        #expect(response.status.code == 402)
        #expect(response.headerFields[values: .wwwAuthenticate].count == 2)
    }

    @Test("a credential is routed to and verified against the offer it claims")
    func routesCredentialToOffer() async throws {
        let middleware = try multiMethodMiddleware()
        guard case let .challenge(challenges, _) = await middleware.evaluate(
            authorization: nil, body: Data(), now: now
        ) else { Issue.record("expected a challenge"); return }
        // Present the second offer's (stripe) credential: it must verify against the stripe
        // binding.
        let stripeCredential = try credential(for: challenges[1])
        let decision = await middleware.evaluate(
            authorization: stripeCredential, body: Data(), now: now
        )
        #expect(isProceed(decision))
    }

    @Test("a credential for a method the route does not offer is rejected")
    func rejectsUnofferedMethod() async throws {
        let middleware = try multiMethodMiddleware()
        let paypal = try binding("paypal")
        let challenge = ChallengeMinter(signer: signer).mint(
            binding: paypal, request: EncodedJSON("e30"),
            expires: Expires(date: now.addingTimeInterval(3600))
        )
        let decision = try await middleware.evaluate(
            authorization: credential(for: challenge), body: Data(), now: now
        )
        // No offer matches paypal, so it is pinned to the primary (tempo) and fails the binding
        // check -- a fresh re-offer of both methods, not a proceed.
        guard case let .challenge(challenges, _) = decision else {
            Issue.record("expected a re-offer"); return
        }
        #expect(challenges.count == 2)
    }

    private func isProceed(_ decision: MPPServerMiddleware.Decision) -> Bool {
        if case .proceed = decision { return true }
        return false
    }
}

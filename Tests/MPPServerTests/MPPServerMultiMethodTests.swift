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

    // §7.4 Accept-Payment negotiation: a credential-less request's advertised offers reflect the
    // client's Accept-Payment header (filter to q>0, order by descending q; absent = accept-any).

    /// The methods advertised in the 402's WWW-Authenticate headers (in order) for a
    /// credential-less request whose Accept-Payment header is `accept` (nil = no header).
    private func advertisedMethods(accept: String?) async throws -> [String] {
        let middleware = try multiMethodMiddleware()
        var fields = HTTPFields()
        if let accept { try fields[#require(HTTPField.Name("Accept-Payment"))] = accept }
        let request = HTTPRequest(
            method: .post, scheme: "https", authority: "api.example.com", path: "/r",
            headerFields: fields
        )
        let (response, _) = await middleware.handle(request, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        return response.headerFields[values: .wwwAuthenticate]
            .flatMap { Challenge.challenges(inHeaderValue: $0) }
            .map(\.method.rawValue)
    }

    @Test("no Accept-Payment advertises every offer in order")
    func noAcceptAdvertisesAll() async throws {
        #expect(try await advertisedMethods(accept: nil) == ["tempo", "stripe"])
    }

    @Test("Accept-Payment filters to the methods the client accepts")
    func filtersToAccepted() async throws {
        #expect(try await advertisedMethods(accept: "stripe/charge") == ["stripe"])
    }

    @Test("q=0 opts a method out of the 402")
    func qZeroOptsOut() async throws {
        let methods = try await advertisedMethods(accept: "tempo/charge;q=0, stripe/charge")
        #expect(methods == ["stripe"])
    }

    @Test("offers are ordered by descending q (most-preferred first), reordering the defaults")
    func ordersByQuality() async throws {
        let methods = try await advertisedMethods(accept: "stripe/charge;q=1, tempo/charge;q=0.5")
        #expect(methods == ["stripe", "tempo"])
    }

    @Test("a preference matching no offer falls back to advertising all of them")
    func fallbackWhenNoneMatch() async throws {
        #expect(try await advertisedMethods(accept: "paypal/charge") == ["tempo", "stripe"])
    }

    @Test("a wildcard preference accepts every offer")
    func wildcardAcceptsAll() async throws {
        #expect(try await advertisedMethods(accept: "*/charge") == ["tempo", "stripe"])
    }

    @Test("a malformed Accept-Payment is treated as absent (all offers)")
    func malformedTreatedAsAbsent() async throws {
        #expect(try await advertisedMethods(accept: "not-a-valid-header") == ["tempo", "stripe"])
    }

    @Test("among equally-specific ranges the higher q wins, regardless of order")
    func sameSpecificityHigherQWins() async throws {
        // tempo appears twice (same specificity); q=1 must win over q=0, so tempo is kept (and
        // stripe, with no matching range, is dropped) -- not picked positionally as q=0.
        let lowThenHigh = try await advertisedMethods(accept: "tempo/charge;q=0, tempo/charge;q=1")
        let highThenLow = try await advertisedMethods(accept: "tempo/charge;q=1, tempo/charge;q=0")
        #expect(lowThenHigh == ["tempo"])
        #expect(highThenLow == ["tempo"])
    }

    @Test("multiple Accept-Payment header lines are combined (RFC 9110 §5.2)")
    func multipleHeaderLinesCombined() async throws {
        let middleware = try multiMethodMiddleware()
        var fields = HTTPFields()
        let name = try #require(HTTPField.Name("Accept-Payment"))
        fields.append(HTTPField(name: name, value: "tempo/charge;q=0.5"))
        fields.append(HTTPField(name: name, value: "stripe/charge;q=1"))
        let request = HTTPRequest(
            method: .post, scheme: "https", authority: "api.example.com", path: "/r",
            headerFields: fields
        )
        let (response, _) = await middleware.handle(request, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        let methods = response.headerFields[values: .wwwAuthenticate]
            .flatMap { Challenge.challenges(inHeaderValue: $0) }
            .map(\.method.rawValue)
        // Both lines are honored: stripe (q=1) ahead of tempo (q=0.5).
        #expect(methods == ["stripe", "tempo"])
    }

    private func isProceed(_ decision: MPPServerMiddleware.Decision) -> Bool {
        if case .proceed = decision { return true }
        return false
    }
}

import Foundation
import MPPBodyDigest
import MPPCore
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §5.1.2 (id binding) + §11.3/§11.5 (single use).
// The verifier runs parse -> HMAC-verify -> binding-pin -> expiry -> digest ->
// consume(last).
/// A method that accepts any challenge and mints a receipt with a fixed settlement
/// reference, to exercise receipt minting (MPPServer ships no concrete method).
/// Internal so the middleware suite in this target can reuse it.
struct AcceptingMethod: PaymentMethodServer {
    let reference: String
    func supports(_: Challenge) -> Bool {
        true
    }

    func verify(_ credential: Credential, now: Date) async throws -> Receipt {
        Receipt(
            method: credential.challenge.method,
            timestamp: RFC3339DateTime(date: now),
            reference: reference
        )
    }
}

@Suite("PaymentVerifier")
struct PaymentVerifierTests {
    private func signer() -> ChallengeSigner {
        ChallengeSigner(secret: secret)
    }

    /// The route binding the signed test credentials are minted for.
    private func expected() throws -> RouteBinding {
        try makeBinding()
    }

    /// Builds a credential whose echoed challenge is signed by `signer`.
    private func signedCredential(
        signer: ChallengeSigner,
        digest: String? = nil,
        expires: Expires? = nil
    ) throws -> Credential {
        let unsigned = try Challenge(
            id: "unsigned", realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30"), digest: digest, expires: expires
        )
        let signed = unsigned.withID(signer.computeID(for: unsigned))
        return Credential(challenge: signed, payload: ["proof": "0xabc"])
    }

    private func rejection(_ outcome: PaymentVerifier.Outcome) -> PaymentVerifier.Rejection? {
        if case let .rejected(reason) = outcome { return reason }
        return nil
    }

    private func verified(_ outcome: PaymentVerifier.Outcome) -> MPPVerified? {
        if case let .verified(token) = outcome { return token }
        return nil
    }

    @Test("verifies a well-formed, signed, un-expired, route-matched credential")
    func verifiesValidCredential() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: signer()).headerValue
        let outcome = try await verifier.verify(
            authorization: header, body: Data(), now: now, expecting: expected()
        )
        let token = try #require(verified(outcome))
        #expect(token.credential.challenge.method.rawValue == "tempo")
        // Protocol-only verification (no method registered) settles nothing, so
        // it mints no receipt.
        #expect(token.receipt == nil)
    }

    @Test("a registered method's settlement reference is minted into the receipt")
    func mintsReceiptFromMethod() async throws {
        let verifier = PaymentVerifier(
            signer: signer(),
            replayStore: InMemoryReplayStore(),
            methods: [AcceptingMethod(reference: "0xtxref")]
        )
        let header = try signedCredential(signer: signer()).headerValue
        let outcome = try await verifier.verify(
            authorization: header, body: Data(), now: now, expecting: expected()
        )
        let receipt = try #require(verified(outcome)?.receipt)
        #expect(receipt.status == .success)
        #expect(receipt.method.rawValue == "tempo") // the challenge's method
        #expect(receipt.reference == "0xtxref") // the method's settlement reference
        #expect(receipt.timestamp.date == now) // the injected verification time
    }

    @Test("rejects a non-Payment Authorization value")
    func rejectsMalformed() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let outcome = try await verifier.verify(
            authorization: "Bearer abc", body: Data(), now: now, expecting: expected()
        )
        #expect(rejection(outcome) == .malformedCredential)
    }

    @Test("rejects a challenge this server did not sign")
    func rejectsUnsignedChallenge() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let forged = try Challenge(
            id: "forged", realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30")
        )
        let header = try Credential(challenge: forged, payload: ["proof": "x"]).headerValue
        let outcome = try await verifier.verify(
            authorization: header, body: Data(), now: now, expecting: expected()
        )
        #expect(rejection(outcome) == .invalidChallenge)
    }

    @Test("rejects a credential signed under a different secret")
    func rejectsWrongSecret() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: ChallengeSigner(secret: Data("other".utf8)))
            .headerValue
        let outcome = try await verifier.verify(
            authorization: header, body: Data(), now: now, expecting: expected()
        )
        #expect(rejection(outcome) == .invalidChallenge)
    }

    @Test("rejects a valid credential presented to the wrong route (confused deputy)")
    func rejectsBindingMismatch() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: signer()).headerValue // realm api.example.com
        let otherRoute = try RouteBinding(
            realm: "other.example.com", method: MethodName("tempo"), intent: .charge
        )
        let outcome = await verifier.verify(
            authorization: header, body: Data(), now: now, expecting: otherRoute
        )
        #expect(rejection(outcome) == .bindingMismatch)
    }

    @Test("rejects a credential whose intent differs from the route's")
    func rejectsIntentMismatch() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: signer()).headerValue // intent: .charge
        let sessionRoute = try RouteBinding(
            realm: "api.example.com", method: MethodName("tempo"), intent: .session
        )
        let outcome = await verifier.verify(
            authorization: header, body: Data(), now: now, expecting: sessionRoute
        )
        #expect(rejection(outcome) == .bindingMismatch)
    }

    @Test("rejects a credential whose method differs from the route's")
    func rejectsMethodMismatch() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: signer()).headerValue // method: tempo
        let stripeRoute = try RouteBinding(
            realm: "api.example.com", method: MethodName("stripe"), intent: .charge
        )
        let outcome = await verifier.verify(
            authorization: header, body: Data(), now: now, expecting: stripeRoute
        )
        #expect(rejection(outcome) == .bindingMismatch)
    }

    @Test("rejects an expired challenge but accepts one expiring later")
    func enforcesExpiry() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let past = try signedCredential(signer: signer(), expires: Expires("2025-01-01T00:00:00Z"))
        let future = try signedCredential(
            signer: signer(),
            expires: Expires("2027-01-01T00:00:00Z")
        )
        let binding = try expected()
        let expired = try await verifier.verify(
            authorization: past.headerValue, body: Data(), now: now, expecting: binding
        )
        let valid = try await verifier.verify(
            authorization: future.headerValue, body: Data(), now: now, expecting: binding
        )
        #expect(rejection(expired) == .expired)
        #expect(verified(valid) != nil)
    }

    @Test("accepts a matching body digest and rejects a mismatched one")
    func enforcesBodyDigest() async throws {
        let body = Data("the original body".utf8)
        let digest = ContentDigest.compute(body)
        let matchHeader = try signedCredential(signer: signer(), digest: digest).headerValue
        let mismatchHeader = try signedCredential(signer: signer(), digest: digest).headerValue
        let binding = try expected()
        let okOutcome = await PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
            .verify(authorization: matchHeader, body: body, now: now, expecting: binding)
        let bad = await PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
            .verify(
                authorization: mismatchHeader,
                body: Data("tampered".utf8),
                now: now,
                expecting: binding
            )
        #expect(verified(okOutcome) != nil)
        #expect(rejection(bad) == .digestMismatch)
    }

    @Test("rejects a replayed credential; the first use wins")
    func rejectsReplay() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: signer()).headerValue
        let binding = try expected()
        let first = await verifier.verify(
            authorization: header,
            body: Data(),
            now: now,
            expecting: binding
        )
        let second = await verifier.verify(
            authorization: header,
            body: Data(),
            now: now,
            expecting: binding
        )
        #expect(verified(first) != nil)
        #expect(rejection(second) == .replayed)
    }

    @Test("an invalid credential does not burn the challenge id (consume is last)")
    func invalidCredentialDoesNotConsume() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let body = Data("body".utf8)
        let header = try signedCredential(signer: signer(), digest: ContentDigest.compute(body))
            .headerValue
        let binding = try expected()
        // Wrong body: rejected at the digest gate, before consume.
        let rejected = await verifier.verify(
            authorization: header, body: Data("wrong".utf8), now: now, expecting: binding
        )
        #expect(rejection(rejected) == .digestMismatch)
        // The id was not consumed, so the correct body still verifies.
        let accepted = await verifier.verify(
            authorization: header, body: body, now: now, expecting: binding
        )
        #expect(verified(accepted) != nil)
    }

    @Test("under concurrent verification of one credential, exactly one is verified")
    func concurrentSingleVerification() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: signer()).headerValue
        let binding = try expected()
        let attempts = 50
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< attempts {
                group.addTask {
                    if case .verified = await verifier.verify(
                        authorization: header, body: Data(), now: now, expecting: binding
                    ) { return true }
                    return false
                }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        #expect(wins == 1)
    }
}

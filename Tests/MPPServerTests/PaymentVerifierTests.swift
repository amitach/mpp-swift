import Foundation
import MPPBodyDigest
import MPPCore
import MPPServer
import Testing

// Spec: draft-httpauth-payment-00 §5.1.2 (id binding) + §11.3/§11.5 (single use).
// The verifier runs parse -> HMAC-verify -> expiry -> digest -> consume(last).
@Suite("PaymentVerifier")
struct PaymentVerifierTests {
    private let secret = Data("test-secret-key-12345".utf8)
    private let now = Date(timeIntervalSince1970: 1_767_312_000) // 2026-01-02T00:00:00Z

    private func signer() -> ChallengeSigner {
        ChallengeSigner(secret: secret)
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
        let signed = Challenge(
            id: signer.computeID(for: unsigned), realm: unsigned.realm, method: unsigned.method,
            intent: unsigned.intent, request: unsigned.request, digest: unsigned.digest,
            expires: unsigned.expires
        )
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

    @Test("verifies a well-formed, signed, un-expired credential")
    func verifiesValidCredential() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let credential = try signedCredential(signer: signer())
        let outcome = try await verifier.verify(
            authorization: credential.headerValue, body: Data(), now: now
        )
        let token = try #require(verified(outcome))
        #expect(token.credential.challenge.method.rawValue == "tempo")
    }

    @Test("rejects a non-Payment Authorization value")
    func rejectsMalformed() async {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let outcome = await verifier.verify(authorization: "Bearer abc", body: Data(), now: now)
        #expect(rejection(outcome) == .malformedCredential)
    }

    @Test("rejects a challenge this server did not sign")
    func rejectsUnsignedChallenge() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        // A challenge with an arbitrary id was never signed by our secret.
        let forged = try Challenge(
            id: "forged", realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30")
        )
        let credential = Credential(challenge: forged, payload: ["proof": "x"])
        let outcome = try await verifier.verify(
            authorization: credential.headerValue, body: Data(), now: now
        )
        #expect(rejection(outcome) == .invalidChallenge)
    }

    @Test("rejects a credential signed under a different secret")
    func rejectsWrongSecret() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let credential = try signedCredential(signer: ChallengeSigner(secret: Data("other".utf8)))
        let outcome = try await verifier.verify(
            authorization: credential.headerValue, body: Data(), now: now
        )
        #expect(rejection(outcome) == .invalidChallenge)
    }

    @Test("rejects an expired challenge but accepts one expiring later")
    func enforcesExpiry() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let past = try signedCredential(signer: signer(), expires: Expires("2025-01-01T00:00:00Z"))
        let future = try signedCredential(
            signer: signer(),
            expires: Expires("2027-01-01T00:00:00Z")
        )
        let expired = try await verifier.verify(
            authorization: past.headerValue, body: Data(), now: now
        )
        let valid = try await verifier.verify(
            authorization: future.headerValue, body: Data(), now: now
        )
        #expect(rejection(expired) == .expired)
        #expect(verified(valid) != nil)
    }

    @Test("accepts a matching body digest and rejects a mismatched one")
    func enforcesBodyDigest() async throws {
        let body = Data("the original body".utf8)
        let digest = ContentDigest.compute(body)
        let match = try signedCredential(signer: signer(), digest: digest)
        let mismatch = try signedCredential(signer: signer(), digest: digest)
        let okOutcome = try await verifier(signer()).verify(
            authorization: match.headerValue, body: body, now: now
        )
        let bad = try await verifier(signer()).verify(
            authorization: mismatch.headerValue, body: Data("tampered".utf8), now: now
        )
        #expect(verified(okOutcome) != nil)
        #expect(rejection(bad) == .digestMismatch)
    }

    @Test("rejects a replayed credential; the first use wins")
    func rejectsReplay() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let credential = try signedCredential(signer: signer())
        let header = try credential.headerValue
        let first = await verifier.verify(authorization: header, body: Data(), now: now)
        let second = await verifier.verify(authorization: header, body: Data(), now: now)
        #expect(verified(first) != nil)
        #expect(rejection(second) == .replayed)
    }

    @Test("an invalid credential does not burn the challenge id (consume is last)")
    func invalidCredentialDoesNotConsume() async throws {
        let store = InMemoryReplayStore()
        let verifier = PaymentVerifier(signer: signer(), replayStore: store)
        let body = Data("body".utf8)
        let credential = try signedCredential(signer: signer(), digest: ContentDigest.compute(body))
        let header = try credential.headerValue
        // Wrong body: rejected at the digest gate, before consume.
        let rejected = await verifier.verify(
            authorization: header,
            body: Data("wrong".utf8),
            now: now
        )
        #expect(rejection(rejected) == .digestMismatch)
        // The id was not consumed, so the correct body still verifies.
        let accepted = await verifier.verify(authorization: header, body: body, now: now)
        #expect(verified(accepted) != nil)
    }

    @Test("under concurrent verification of one credential, exactly one is verified")
    func concurrentSingleVerification() async throws {
        let verifier = PaymentVerifier(signer: signer(), replayStore: InMemoryReplayStore())
        let header = try signedCredential(signer: signer()).headerValue
        let attempts = 50
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< attempts {
                group.addTask {
                    if case .verified = await verifier.verify(
                        authorization: header, body: Data(), now: now
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

    private func verifier(_ signer: ChallengeSigner) -> PaymentVerifier {
        PaymentVerifier(signer: signer, replayStore: InMemoryReplayStore())
    }
}

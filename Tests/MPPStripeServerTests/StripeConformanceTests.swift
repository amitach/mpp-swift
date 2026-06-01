import Foundation
import MPPCore
import MPPServer
import MPPStripe
import Testing
@testable import MPPStripeServer

// Hermetic end-to-end conformance for the Stripe rail: the real client method builds an SPT
// credential for a server-minted stripe/charge challenge, and the real server pipeline
// (PaymentVerifier + ChallengeSigner) verifies it, settling via a stub PaymentIntent client. No
// Stripe account or network. Proves the MPP 402 handshake (challenge -> credential -> receipt)
// works end to end for the Stripe method, across the client/server module split.
@Suite("Stripe charge conformance (hermetic end-to-end)")
struct StripeConformanceTests {
    private let secret = Data("stripe-conformance-secret-key-0123456789abcd".utf8)
    private let now = Date(timeIntervalSince1970: 1_767_312_000)

    private func chargeBinding() throws -> RouteBinding {
        try RouteBinding(realm: "api.example.com", method: MethodName("stripe"), intent: .charge)
    }

    private func mintedChallenge(_ signer: ChallengeSigner) throws -> Challenge {
        let request = EncodedJSON(json: .object([
            "amount": .string("1000"),
            "currency": .string("usd"),
            "methodDetails": .object([
                "networkId": .string("internal"),
                "paymentMethodTypes": .array([.string("card")]),
            ]),
        ]))
        return try ChallengeMinter(signer: signer).mint(binding: chargeBinding(), request: request)
    }

    @Test("client builds an SPT credential the server verifier settles into a receipt")
    func endToEnd() async throws {
        let signer = ChallengeSigner(secret: secret)
        let challenge = try mintedChallenge(signer)

        let client = StripeChargeMethod(
            tokenProvider: StripeTokenProvider { _ in "spt_live_like" }, externalId: "order_1"
        )
        let credential = try await client.buildCredential(for: challenge)
        let header = try credential.headerValue

        let verifier = StripeChargeVerifier(client: StubPaymentIntent(
            status: "succeeded",
            id: "pi_e2e"
        ))
        let pipeline = PaymentVerifier(
            signer: signer, replayStore: InMemoryReplayStore(), methods: [verifier]
        )
        let outcome = try await pipeline.verify(
            authorization: header, body: Data(), now: now, expecting: chargeBinding()
        )
        guard case let .verified(verified) = outcome else {
            Issue.record("expected verified, got \(outcome)"); return
        }
        #expect(verified.receipt?.reference == "pi_e2e")
        #expect(verified.receipt?.method == StripeMethod.name)
        let extras = verified.receipt?.extras ?? [:]
        #expect(receiptString(extras["externalId"]) == "order_1")
    }

    @Test("a server PaymentIntent that requires action maps to a verification-failed rejection")
    func rejectionEndToEnd() async throws {
        let signer = ChallengeSigner(secret: secret)
        let challenge = try mintedChallenge(signer)
        let client = StripeChargeMethod(tokenProvider: StripeTokenProvider { _ in "spt_x" })
        let header = try await client.buildCredential(for: challenge).headerValue

        let verifier = StripeChargeVerifier(client: StubPaymentIntent(status: "requires_action"))
        let pipeline = PaymentVerifier(
            signer: signer, replayStore: InMemoryReplayStore(), methods: [verifier]
        )
        let outcome = try await pipeline.verify(
            authorization: header, body: Data(), now: now, expecting: chargeBinding()
        )
        guard case .rejected = outcome else {
            Issue.record("expected rejected, got \(outcome)"); return
        }
    }
}

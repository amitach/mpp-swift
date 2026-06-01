import Foundation
import MPPCore
import MPPStripe
import Testing
@testable import MPPStripeServer

@Suite("StripeChargeVerifier")
struct StripeChargeVerifierTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a succeeded PaymentIntent yields a success receipt referencing the PI id")
    func succeeded() async throws {
        let stub = StubPaymentIntent(status: "succeeded", id: "pi_ok")
        let verifier = StripeChargeVerifier(client: stub)
        let receipt = try await verifier.verify(stripeCredential(externalId: "order_7"), now: now)
        #expect(receipt.reference == "pi_ok")
        #expect(receipt.method == StripeMethod.name)
        #expect(receipt.status == .success)
        #expect(receiptString(receipt.extras["externalId"]) == "order_7")
    }

    @Test("no externalId in the credential means none in the receipt")
    func noExternalId() async throws {
        let verifier = StripeChargeVerifier(client: StubPaymentIntent())
        let receipt = try await verifier.verify(stripeCredential(), now: now)
        #expect(receipt.extras["externalId"] == nil)
    }

    @Test("requires_action is rejected (not settleable here)")
    func requiresAction() async {
        let verifier = StripeChargeVerifier(client: StubPaymentIntent(status: "requires_action"))
        await expectError(verifier) {
            if case .paymentActionRequired = $0 { return true }; return false
        }
    }

    @Test("a replayed idempotent request is rejected as already processed")
    func replayed() async {
        let verifier = StripeChargeVerifier(client: StubPaymentIntent(replayed: true))
        await expectError(verifier) { if case .alreadyProcessed = $0 { return true }; return false }
    }

    @Test("a non-succeeded status is rejected with the raw status")
    func unexpectedStatus() async {
        let verifier = StripeChargeVerifier(client: StubPaymentIntent(status: "processing"))
        await expectError(verifier) {
            if case let .unexpectedStatus(status) = $0 { return status == "processing" }
            return false
        }
    }

    @Test("a PaymentIntent-creation failure surfaces as paymentIntentFailed")
    func creationFails() async {
        let verifier =
            StripeChargeVerifier(client: StubPaymentIntent(throwing: StripeAPIError
                    .transport("boom")))
        await expectError(verifier) {
            if case .paymentIntentFailed = $0 { return true }; return false
        }
    }

    @Test("a missing or empty spt is rejected before any Stripe call")
    func missingSPT() async throws {
        let verifier = StripeChargeVerifier(client: StubPaymentIntent())
        try await expectError(verifier, credential: stripeCredential(spt: nil)) {
            if case .missingSPT = $0 { return true }; return false
        }
        try await expectError(verifier, credential: stripeCredential(spt: .string(""))) {
            if case .missingSPT = $0 { return true }; return false
        }
    }

    @Test("an amount that overflows Int is rejected")
    func amountOverflow() async throws {
        let huge = String(repeating: "9", count: 40)
        let challenge = try stripeChargeChallenge(request: .object([
            "amount": .string(huge), "currency": .string("usd"),
            "methodDetails": .object([
                "networkId": .string("internal"), "paymentMethodTypes": .array([.string("card")]),
            ]),
        ]))
        let verifier = StripeChargeVerifier(client: StubPaymentIntent())
        try await expectError(verifier, credential: stripeCredential(challenge: challenge)) {
            if case .amountOverflow = $0 { return true }; return false
        }
    }

    @Test("supports stripe/charge with a decodable request; rejects otherwise")
    func supports() throws {
        let verifier = StripeChargeVerifier(client: StubPaymentIntent())
        let valid = try stripeChargeChallenge()
        #expect(verifier.supports(valid))
        let undecodable = try stripeChargeChallenge(request: .object(["amount": .string("1")]))
        #expect(!verifier.supports(undecodable))
    }

    @Test(
        "metadata = mpp_* analytics merged with user metadata (user wins), server id is the realm"
    )
    func metadata() async throws {
        let stub = StubPaymentIntent()
        let verifier = StripeChargeVerifier(client: stub)
        let challenge = try stripeChargeChallenge(request: .object([
            "amount": .string("1000"), "currency": .string("usd"),
            "methodDetails": .object([
                "networkId": .string("internal"),
                "paymentMethodTypes": .array([.string("card")]),
                // A user `challenge_id` MUST NOT override the spec reconciliation key; a user
                // `mpp_*` key wins (reference-SDK behavior).
                "metadata": .object([
                    "plan": .string("pro"),
                    "mpp_is_mpp": .string("false"),
                    "challenge_id": .string("forged"),
                ]),
            ]),
        ]))
        _ = try await verifier.verify(stripeCredential(challenge: challenge), now: now)
        let captured = await stub.captured
        let metadata = try #require(captured?.metadata)
        #expect(metadata["challenge_id"] == "c1") // spec key, applied last, NOT overridable
        #expect(metadata["mpp_version"] == "1")
        #expect(metadata["mpp_intent"] == "charge")
        #expect(metadata["mpp_challenge_id"] == "c1")
        #expect(metadata["mpp_server_id"] == "https://api.example.com")
        #expect(metadata["plan"] == "pro")
        #expect(metadata["mpp_is_mpp"] == "false") // user override wins for the mpp_* namespace
        #expect(metadata["mpp_client_id"] == nil) // no source on a Stripe credential
    }

    @Test("the idempotency key is stable and namespaced per (challenge, spt)")
    func idempotencyKey() async throws {
        let stub = StubPaymentIntent()
        let verifier = StripeChargeVerifier(client: stub)
        _ = try await verifier.verify(stripeCredential(), now: now)
        let captured = await stub.captured
        let key = try #require(captured?.idempotencyKey)
        #expect(key.hasPrefix("mpp-swift_c1_"))
        let hex = key.dropFirst("mpp-swift_c1_".count)
        #expect(hex.count == 64) // sha256 hex of the spt
        let allHex = hex.allSatisfy(\.isHexDigit)
        #expect(allHex)
    }

    @Test("the charge description is forwarded to the PaymentIntent")
    func descriptionForwarded() async throws {
        let stub = StubPaymentIntent()
        let verifier = StripeChargeVerifier(client: stub)
        let challenge = try stripeChargeChallenge(request: .object([
            "amount": .string("1000"), "currency": .string("usd"),
            "description": .string("a coffee"),
            "methodDetails": .object([
                "networkId": .string("internal"),
                "paymentMethodTypes": .array([.string("card")]),
            ]),
        ]))
        _ = try await verifier.verify(stripeCredential(challenge: challenge), now: now)
        let captured = await stub.captured
        #expect(captured?.description == "a coffee")
    }

    @Test("a valid Connect settlement reaches the PaymentIntent request")
    func connectApply() async throws {
        let settlement = StripeConnectSettlement(
            applicationFeeAmount: 10, onBehalfOf: "acct_merchant",
            transferData: StripeTransferData(destination: "acct_dest", amount: 50),
            transferGroup: "grp_1", stripeAccount: "acct_conn"
        )
        let stub = StubPaymentIntent()
        let verifier = StripeChargeVerifier(client: stub, connect: .fixed(settlement))
        _ = try await verifier.verify(stripeCredential(), now: now)
        let captured = await stub.captured
        #expect(captured?.settlement == settlement)
    }

    @Test("each invalid Connect settlement is rejected before the Stripe call")
    func connectRejections() async throws {
        // amount is 1000.
        try await expectConnect(.init(stripeAccount: ""), .emptyStripeAccount)
        try await expectConnect(.init(onBehalfOf: ""), .emptyOnBehalfOf)
        try await expectConnect(.init(applicationFeeAmount: -1), .applicationFeeNegative)
        try await expectConnect(.init(applicationFeeAmount: 1001), .applicationFeeExceedsAmount)
        try await expectConnect(
            .init(transferData: StripeTransferData(destination: "")), .emptyTransferDestination
        )
        try await expectConnect(
            .init(transferData: StripeTransferData(destination: "d", amount: -1)),
            .transferAmountNegative
        )
        try await expectConnect(
            .init(transferData: StripeTransferData(destination: "d", amount: 1001)),
            .transferAmountExceedsAmount
        )
    }

    // MARK: - Helpers

    private func expectError(
        _ verifier: StripeChargeVerifier,
        credential: Credential? = nil,
        _ matches: (StripeChargeVerifier.VerifyError) -> Bool
    ) async {
        let cred: Credential
        do {
            cred = try credential ?? stripeCredential()
        } catch {
            Issue.record("setup failed: \(error)"); return
        }
        do {
            _ = try await verifier.verify(cred, now: now)
            Issue.record("expected a VerifyError")
        } catch {
            #expect(matches(error), "unexpected error: \(error)")
        }
    }

    private func expectConnect(
        _ settlement: StripeConnectSettlement, _ expected: StripeConnectViolation
    ) async throws {
        let verifier = StripeChargeVerifier(
            client: StubPaymentIntent(),
            connect: .fixed(settlement)
        )
        do {
            _ = try await verifier.verify(stripeCredential(), now: now)
            Issue.record("expected connectInvalid(\(expected))")
        } catch let error as StripeChargeVerifier.VerifyError {
            guard case let .connectInvalid(violation) = error, violation == expected else {
                Issue.record("expected connectInvalid(\(expected)), got \(error)"); return
            }
        }
    }
}

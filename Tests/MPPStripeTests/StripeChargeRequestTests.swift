import Foundation
import MPPCore
import Testing
@testable import MPPStripe

@Suite("StripeChargeRequest decode")
struct StripeChargeRequestTests {
    @Test("decodes a valid request: base-units amount, currency, networkId, payment method types")
    func decodesValid() throws {
        let request = stripeRequest(
            amount: .string("1000"),
            currency: .string("usd"),
            description: .string("a coffee"),
            externalId: .string("order_9"),
            recipient: .string("acct_seller"),
            methodDetails: .object([
                "networkId": .string("internal"),
                "paymentMethodTypes": .array([.string("card"), .string("link")]),
                "metadata": .object(["plan": .string("pro")]),
            ])
        )
        let decoded = try StripeChargeRequest(challenge: stripeChallenge(request: request))
        #expect(decoded.amount.rawValue == "1000")
        #expect(decoded.currency == "usd")
        #expect(decoded.description == "a coffee")
        #expect(decoded.externalId == "order_9")
        #expect(decoded.recipient == "acct_seller")
        #expect(decoded.networkId == "internal")
        #expect(decoded.paymentMethodTypes == ["card", "link"])
        #expect(decoded.metadata == ["plan": "pro"])
    }

    @Test("optional fields absent decode to nil")
    func optionalAbsent() throws {
        let decoded = try StripeChargeRequest(challenge: stripeChallenge())
        #expect(decoded.description == nil)
        #expect(decoded.externalId == nil)
        #expect(decoded.recipient == nil)
        #expect(decoded.metadata == nil)
    }

    @Test("a non-base64url request fails with notBase64URL")
    func notBase64URL() throws {
        let challenge = try stripeChallengeRawRequest("!!! not base64url !!!")
        assertDecodeFails(challenge) { if case .notBase64URL = $0 { return true }; return false }
    }

    @Test("a missing required field (currency) fails with invalidJSON")
    func missingCurrency() throws {
        let challenge = try stripeChallenge(request: stripeRequest(currency: nil))
        assertDecodeFails(challenge) { if case .invalidJSON = $0 { return true }; return false }
    }

    @Test("missing methodDetails fails with invalidJSON")
    func missingMethodDetails() throws {
        let challenge = try stripeChallenge(request: stripeRequest(methodDetails: nil))
        assertDecodeFails(challenge) { if case .invalidJSON = $0 { return true }; return false }
    }

    @Test("missing networkId fails with invalidJSON")
    func missingNetworkId() throws {
        let challenge = try stripeChallenge(request: stripeRequest(
            methodDetails: .object(["paymentMethodTypes": .array([.string("card")])])
        ))
        assertDecodeFails(challenge) { if case .invalidJSON = $0 { return true }; return false }
    }

    @Test("a non-canonical amount fails with invalidAmount")
    func invalidAmount() throws {
        let challenge = try stripeChallenge(request: stripeRequest(amount: .string("01")))
        assertDecodeFails(challenge) { if case .invalidAmount = $0 { return true }; return false }
    }

    @Test("an empty paymentMethodTypes fails with emptyPaymentMethodTypes")
    func emptyPaymentMethodTypes() throws {
        let challenge = try stripeChallenge(request: stripeRequest(
            methodDetails: .object([
                "networkId": .string("internal"),
                "paymentMethodTypes": .array([]),
            ])
        ))
        assertDecodeFails(challenge) {
            if case .emptyPaymentMethodTypes = $0 { return true }; return false
        }
    }

    private func assertDecodeFails(
        _ challenge: Challenge,
        _ matches: (StripeChargeRequest.DecodingFailure) -> Bool
    ) {
        do {
            _ = try StripeChargeRequest(challenge: challenge)
            Issue.record("expected a DecodingFailure")
        } catch {
            #expect(matches(error), "unexpected failure: \(error)")
        }
    }
}

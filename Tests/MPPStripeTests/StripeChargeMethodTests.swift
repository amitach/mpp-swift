import Foundation
import MPPClient
import MPPCore
import Testing
@testable import MPPStripe

@Suite("StripeChargeMethod")
struct StripeChargeMethodTests {
    @Test("paymentRanges advertises exactly one range (stripe/charge)")
    func paymentRanges() throws {
        let method = StripeChargeMethod(tokenProvider: fixedTokenProvider())
        #expect(method.paymentRanges.count == 1)
        // The range is built from StripeMethod.name + .charge; AcceptPayment.format round-trips it.
        let expected = try PaymentRange(method: .value(StripeMethod.name), intent: .value(.charge))
        #expect(method.paymentRanges == [expected])
    }

    @Test("supports a valid stripe/charge challenge; rejects wrong method/intent/undecodable")
    func supports() throws {
        let method = StripeChargeMethod(tokenProvider: fixedTokenProvider())
        #expect(try method.supports(stripeChallenge()))
        #expect(try !method.supports(stripeChallenge(method: "tempo")))
        #expect(try !method.supports(stripeChallenge(intent: .subscription)))
        #expect(try !method.supports(stripeChallenge(request: stripeRequest(currency: nil))))
        #expect(try !method.supports(stripeChallenge(request: stripeRequest(
            methodDetails: .object([
                "networkId": .string("internal"), "paymentMethodTypes": .array([]),
            ])
        ))))
    }

    @Test("buildCredential carries the SPT and no source")
    func buildCredentialSPT() async throws {
        let method = StripeChargeMethod(tokenProvider: fixedTokenProvider("spt_abc"))
        let credential = try await method.buildCredential(for: stripeChallenge())
        #expect(jsonString(credential.payload["spt"]) == "spt_abc")
        #expect(credential.source == nil)
        #expect(credential.payload["externalId"] == nil)
    }

    @Test("an externalId configured on the method is echoed into the credential payload")
    func buildCredentialExternalId() async throws {
        let method = StripeChargeMethod(
            tokenProvider: fixedTokenProvider("spt_abc"), externalId: "order_456"
        )
        let credential = try await method.buildCredential(for: stripeChallenge())
        #expect(jsonString(credential.payload["externalId"]) == "order_456")
        #expect(jsonString(credential.payload["spt"]) == "spt_abc")
    }

    @Test("the token request handed to the provider carries the resolved charge facts")
    func tokenRequestFacts() async throws {
        let captured = TokenRequestBox()
        let provider = StripeTokenProvider { request in
            await captured.set(request)
            return "spt_abc"
        }
        let method = StripeChargeMethod(tokenProvider: provider)
        _ = try await method.buildCredential(for: stripeChallenge(
            request: stripeRequest(amount: .string("250"), currency: .string("eur"))
        ))
        let request = try #require(await captured.value)
        #expect(request.challengeId == "c1")
        #expect(request.realm == "https://api.example.com")
        #expect(request.amount.rawValue == "250")
        #expect(request.currency == "eur")
        #expect(request.networkId == "internal")
        #expect(request.paymentMethodTypes == ["card"])
    }

    @Test("a token provider that refuses surfaces as tokenProviderFailed (no credential)")
    func providerRefuses() async throws {
        let method = StripeChargeMethod(tokenProvider: .failing)
        await #expect(throws: StripeMethodError.self) {
            _ = try await method.buildCredential(for: stripeChallenge())
        }
    }

    @Test("buildCredential on a non-stripe challenge throws wrongMethodOrIntent")
    func wrongMethod() async throws {
        let method = StripeChargeMethod(tokenProvider: fixedTokenProvider())
        do {
            _ = try await method.buildCredential(for: stripeChallenge(method: "tempo"))
            Issue.record("expected wrongMethodOrIntent")
        } catch let error as StripeMethodError {
            guard case .wrongMethodOrIntent = error else {
                Issue.record("unexpected error: \(error)"); return
            }
        }
    }

    @Test("buildCredential on a malformed request throws malformedRequest")
    func malformedRequest() async throws {
        let method = StripeChargeMethod(tokenProvider: fixedTokenProvider())
        do {
            _ = try await method.buildCredential(
                for: stripeChallenge(request: stripeRequest(currency: nil))
            )
            Issue.record("expected malformedRequest")
        } catch let error as StripeMethodError {
            guard case .malformedRequest = error else {
                Issue.record("unexpected error: \(error)"); return
            }
        }
    }
}

/// An actor box to capture the `StripeTokenRequest` the provider closure receives (the closure is
/// `@Sendable`, so it cannot close over mutable local state directly).
private actor TokenRequestBox {
    private(set) var value: StripeTokenRequest?
    func set(_ request: StripeTokenRequest) {
        value = request
    }
}

import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import Testing
@testable import MPPStripeServer

// Live Stripe conformance: settles a real test-mode PaymentIntent against api.stripe.com through
// StripeChargeVerifier + the concrete StripePaymentIntentClient.
//
// Gated on MPP_STRIPE_LIVE_SK, a Stripe TEST secret key (`sk_test_...`) from an account enrolled in
// the Shared Payment Token PRIVATE PREVIEW. Without that enrollment the SPT test-helpers endpoint
// is unavailable, so this cannot run on a plain free account; it is non-required in CI and skips
// when the key is absent. It is not run in the default suite.
private let liveKey = ProcessInfo.processInfo.environment["MPP_STRIPE_LIVE_SK"]

@Suite("Stripe live conformance", .enabled(if: liveKey != nil))
struct StripeLiveConformanceTests {
    @Test("mints a test SPT and settles a real test-mode PaymentIntent to a succeeded receipt")
    func settlesLive() async throws {
        let secretKey = try #require(liveKey)
        let transport = URLSessionTransport()
        let spt = try await mintTestSPT(secretKey: secretKey, transport: transport)

        let request = EncodedJSON(json: .object([
            "amount": .string("1000"),
            "currency": .string("usd"),
            // A description is forwarded to the PaymentIntent; some Stripe accounts (e.g. an Indian
            // export account) require one, so the live charge always carries it.
            "description": .string("MPP Stripe live conformance"),
            "methodDetails": .object([
                "networkId": .string("internal"),
                "paymentMethodTypes": .array([.string("card")]),
            ]),
        ]))
        let challenge = try Challenge(
            id: "live", realm: "api.example.com", method: MethodName("stripe"),
            intent: .charge, request: request
        )
        let credential = try Credential(challenge: challenge, payload: ["spt": .string(spt)])

        let client = try StripePaymentIntentClient(transport: transport, secretKey: secretKey)
        let verifier = StripeChargeVerifier(client: client)
        let receipt = try await verifier.verify(credential, now: Date())
        #expect(receipt.reference.hasPrefix("pi_"))
        #expect(receipt.status == .success)
    }

    /// Mints a test Shared Payment Token via Stripe's test-helpers endpoint (preview).
    private func mintTestSPT(
        secretKey: String, transport: URLSessionTransport
    ) async throws -> String {
        let expiresAt = Int(Date().timeIntervalSince1970) + 3600
        let body = [
            "payment_method=pm_card_visa",
            "usage_limits%5Bcurrency%5D=usd",
            "usage_limits%5Bmax_amount%5D=1000",
            "usage_limits%5Bexpires_at%5D=\(expiresAt)",
        ].joined(separator: "&")
        var fields = HTTPFields()
        fields[.contentType] = "application/x-www-form-urlencoded"
        fields[.authorization] = "Basic " + Data("\(secretKey):".utf8).base64EncodedString()
        // The SPT test-helpers endpoint is private preview, so pin the same preview version.
        if let stripeVersion = HTTPField.Name("Stripe-Version") {
            fields[stripeVersion] = StripeAPI.version
        }
        let request = HTTPRequest(
            method: .post, scheme: "https", authority: "api.stripe.com",
            path: "/v1/test_helpers/shared_payment/granted_tokens", headerFields: fields
        )
        let (response, data) = try await transport.send(request, body: Data(body.utf8))
        guard (200 ..< 300).contains(response.status.code) else {
            let detail = String(bytes: data, encoding: .utf8) ?? ""
            throw LiveError.sptMintFailed(detail)
        }
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(object) = decoded, case let .string(id)? = object["id"] else {
            throw LiveError.sptMintFailed("test-helpers response had no id")
        }
        return id
    }

    private enum LiveError: Error { case sptMintFailed(String) }
}

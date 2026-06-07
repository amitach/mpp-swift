import Foundation
import MPPCore
import MPPX402
import Testing

// The x402 HTTP transport envelopes: the X-PAYMENT / PAYMENT-SIGNATURE PaymentPayload and the 402
// PaymentRequired, both versions, plus the base64(JSON) header codec. Header-value round trips lock
// the wire; version detection reads x402Version.
@Suite("X402 transport")
struct X402TransportTests {
    private static let usdc = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    private static let from = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let payTo = "0x1111111111111111111111111111111111111111"

    private func exactPayload() -> X402ExactPayload {
        X402ExactPayload(
            signature: "0x" + String(repeating: "ab", count: 65),
            authorization: X402AuthorizationWire(
                from: Self.from, recipient: Self.payTo, value: "1000000",
                validAfter: "0", validBefore: "1893456000",
                nonce: "0x" + String(repeating: "cd", count: 32)
            )
        )
    }

    private func requirements() throws -> X402PaymentRequirements {
        try X402PaymentRequirements(
            network: .baseSepolia, amount: Amount("1000000"), asset: Self.usdc, payTo: Self.payTo,
            maxTimeoutSeconds: 300, extra: ["name": .string("USD Coin"), "version": .string("2")]
        )
    }

    // MARK: X402Header

    @Test("the request/response header names differ by version")
    func headerNames() {
        #expect(X402Header.payment(for: .v1) == "X-PAYMENT")
        #expect(X402Header.payment(for: .v2) == "PAYMENT-SIGNATURE")
        #expect(X402Header.paymentResponse(for: .v1) == "X-PAYMENT-RESPONSE")
        #expect(X402Header.paymentResponse(for: .v2) == "PAYMENT-RESPONSE")
    }

    @Test("the header codec round-trips JSON and rejects garbage")
    func headerCodec() {
        let value = JSONValue.object(["a": .string("b"), "n": .integer(7)])
        #expect(X402Header.decode(X402Header.encode(value)) == value)
        #expect(X402Header.decode("not base64!!") == nil)
        // Valid base64 of non-JSON bytes -> nil.
        #expect(X402Header.decode(Data([0xFF, 0xFE]).base64EncodedString()) == nil)
    }

    // MARK: X402PaymentPayload

    @Test("a payment payload round-trips through its header value, per version")
    func paymentPayloadRoundTrip() throws {
        for version in X402Version.allCases {
            let payload = X402PaymentPayload(
                version: version, network: .baseSepolia, payload: exactPayload()
            )
            let object = try #require(payload.json().objectValue)
            #expect(object["x402Version"]?.integerValue == Int64(version.rawValue))
            #expect(object["scheme"]?.stringValue == "exact")
            // The network is written in the version's form.
            #expect(object["network"]?.stringValue == X402Network.baseSepolia
                .wireValue(for: version))
            // Header round-trip recovers the payload (version inferred from x402Version).
            #expect(X402PaymentPayload(headerValue: payload.headerValue) == payload)
        }
    }

    @Test("a malformed payment payload header decodes to nil")
    func paymentPayloadFailClosed() {
        #expect(X402PaymentPayload(headerValue: "not base64") == nil)
        // Missing payload object.
        let noPayload = JSONValue.object([
            "x402Version": .integer(1), "scheme": .string("exact"),
            "network": .string("base-sepolia"),
        ])
        #expect(X402PaymentPayload(json: noPayload) == nil)
        // Unknown x402Version.
        let badVersion = JSONValue.object([
            "x402Version": .integer(99), "scheme": .string("exact"),
            "network": .string("base-sepolia"), "payload": .object(exactPayload().jsonObject()),
        ])
        #expect(X402PaymentPayload(json: badVersion) == nil)
    }

    // MARK: X402PaymentRequired

    @Test("a 402 response round-trips, encoding each accepts entry for its version")
    func paymentRequiredRoundTrip() throws {
        for version in X402Version.allCases {
            let required = try X402PaymentRequired(
                version: version, accepts: [requirements()], error: "payment required"
            )
            let object = try #require(required.json().objectValue)
            #expect(object["x402Version"]?.integerValue == Int64(version.rawValue))
            #expect(object["error"]?.stringValue == "payment required")
            // The single accepts entry uses the version-specific amount key.
            guard case let .array(accepts)? = object["accepts"],
                  let entry = accepts.first?.objectValue else {
                Issue.record("accepts missing"); return
            }
            #expect(entry[version == .v1 ? "maxAmountRequired" : "amount"]?
                .stringValue == "1000000")
            #expect(X402PaymentRequired(headerValue: required.headerValue) == required)
        }
    }

    @Test("a 402 response with an unknown version or a malformed accepts entry fails closed")
    func paymentRequiredFailClosed() {
        let badVersion = JSONValue.object([
            "x402Version": .integer(7), "accepts": .array([]),
        ])
        #expect(X402PaymentRequired(json: badVersion) == nil)
        // A malformed accepts entry rejects the whole response.
        let badEntry = JSONValue.object([
            "x402Version": .integer(2), "accepts": .array([.object(["scheme": .string("exact")])]),
        ])
        #expect(X402PaymentRequired(json: badEntry) == nil)
    }
}

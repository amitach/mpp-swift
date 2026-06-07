import Foundation
import MPPClient
import MPPCore
import MPPEVM
import MPPX402
import Testing

// The MPP <-> x402 translation: an MPP exact/charge challenge becomes x402 PaymentRequirements, and
// an MPP credential becomes the x402 PaymentPayload. The end-to-end check builds the credential
// with
// the real client and confirms the bridged payload carries the same signed authorization.
@Suite("X402 bridge")
struct X402BridgeTests {
    private static let payerKey = Data(repeating: 0, count: 31) + Data([0x01])
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let usdcBaseHex = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let nonce = Data(repeating: 0xAB, count: 32)

    private func chargeChallenge(
        method: MethodName? = nil,
        name: String? = "USD Coin"
    ) throws -> Challenge {
        var details: [String: JSONValue] = [
            "chainId": .integer(84532), "version": .string("2"), "maxTimeoutSeconds": .integer(120),
        ]
        if let name { details["name"] = .string(name) }
        let object: [String: JSONValue] = [
            "amount": .string("1000000"),
            "recipient": .string(Self.recipientHex),
            "currency": .string(Self.usdcBaseHex),
            "methodDetails": .object(details),
        ]
        return try Challenge(
            id: "x402-charge-1", realm: "shop.example",
            method: method ?? X402Method.name, intent: IntentName("charge"),
            request: EncodedJSON(json: .object(object))
        )
    }

    private func credential(for challenge: Challenge) async throws -> Credential {
        let clock: @Sendable () -> Date = { Self.now }
        let nonceSource: @Sendable () -> Data = { Self.nonce }
        let client = try #require(X402ChargeMethod(
            payerPrivateKey: Self.payerKey, now: clock, nonceSource: nonceSource
        ))
        return try await client.buildCredential(for: challenge)
    }

    @Test("a challenge becomes the x402 PaymentRequirements a server advertises")
    func challengeToRequirements() throws {
        let requirements = try X402Bridge.paymentRequirements(for: chargeChallenge())
        #expect(requirements.scheme == "exact")
        #expect(requirements.network == .baseSepolia)
        #expect(try requirements.amount == Amount("1000000"))
        #expect(requirements.asset == Self.usdcBaseHex)
        #expect(requirements.payTo == Self.recipientHex)
        #expect(requirements.maxTimeoutSeconds == 120)
        #expect(requirements.assetName == "USD Coin")
        #expect(requirements.assetVersion == "2")
        #expect(requirements.extra["assetTransferMethod"]?.stringValue == "eip3009")
    }

    @Test("a non-x402 challenge or a missing token domain is rejected")
    func requirementsRejectsBadInput() throws {
        #expect(throws: X402BridgeError.notAnX402Charge) {
            _ = try X402Bridge
                .paymentRequirements(for: chargeChallenge(method: MethodName("stripe")))
        }
        #expect(throws: X402BridgeError.missingTokenDomain) {
            _ = try X402Bridge.paymentRequirements(for: chargeChallenge(name: nil))
        }
    }

    @Test("the credential bridges to an x402 PaymentPayload carrying the same authorization")
    func credentialToPayload() async throws {
        let challenge = try chargeChallenge()
        let credential = try await credential(for: challenge)
        let payload = try X402Bridge.paymentPayload(version: .v2, from: credential)

        #expect(payload.version == .v2)
        #expect(payload.scheme == "exact")
        #expect(payload.network == .baseSepolia)
        // The bridged payload's authorization matches what the client signed.
        let bridged = try #require(payload.payload.authorization.decoded())
        let fromCredential = try #require(
            X402ExactPayload(credentialPayload: credential.payload)?.authorization.decoded()
        )
        #expect(bridged == fromCredential)
        // And it survives the X-PAYMENT header round-trip.
        #expect(X402PaymentPayload(headerValue: payload.headerValue) == payload)
    }

    @Test("a credential whose payload is not an x402 exact payload is rejected")
    func payloadRejectsMalformedCredential() throws {
        let credential = try Credential(
            challenge: chargeChallenge(),
            source: ProofSource.did(
                address: #require(EthereumAddress(hex: Self.recipientHex)), chainId: 84532
            ),
            payload: ["type": .string("bogus")]
        )
        #expect(throws: X402BridgeError.malformedCredentialPayload) {
            _ = try X402Bridge.paymentPayload(version: .v1, from: credential)
        }
    }
}

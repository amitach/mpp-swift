import Foundation
import MPPCore
import MPPEVM
import MPPTempo
import MPPTempoServer
import Testing

// Server-side subscription verification, the counterpart to
// TempoSubscriptionMethodTests: a credential the client mints verifies via
// re-encode-and-compare, and the reject matrix holds (no access key, wrong
// payload, mismatched authorization, an expiry that does not outlive the
// challenge, a forged source). Reuses the module-global `signer(byte:)`/`now`.
@Suite("TempoSubscriptionVerifier")
struct TempoSubscriptionVerifierTests {
    private static let wallet = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let currencyHex = "0x20c0000000000000000000000000000000000001"
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let requestKeyHex = "0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c"
    private static let chainID: UInt64 = 42431
    // The subscription expires in 2030; the challenge deadline below sits before it.
    private static let expiryEpoch: TimeInterval = 1_893_456_000

    private var expiryISO: String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Self.expiryEpoch))
    }

    private func clientMethod(
        accessKey: SubscriptionRequest.AccessKey? = nil
    ) throws -> TempoSubscriptionMethod {
        try #require(TempoSubscriptionMethod(signer: signer(byte: 1), accessKey: accessKey))
    }

    private func challenge(
        chainId: UInt64? = chainID,
        accessKey: JSONValue? = .object([
            "accessKeyAddress": .string(requestKeyHex),
            "keyType": .string("secp256k1"),
        ]),
        expires: Expires? = nil,
        method: String = "tempo",
        intent: String = "subscription"
    ) throws -> Challenge {
        var methodDetails: [String: JSONValue] = [:]
        if let accessKey { methodDetails["accessKey"] = accessKey }
        if let chainId { methodDetails["chainId"] = .integer(Int64(chainId)) }
        var object: [String: JSONValue] = [
            "amount": .string("1000000"),
            "currency": .string(Self.currencyHex),
            "recipient": .string(Self.recipientHex),
            "periodCount": .string("1"),
            "periodUnit": .string("week"),
            "subscriptionExpires": .string(expiryISO),
        ]
        if !methodDetails.isEmpty { object["methodDetails"] = .object(methodDetails) }
        return try Challenge(
            id: "sub-1", realm: realm, method: MethodName(method),
            intent: IntentName(intent), request: EncodedJSON(json: .object(object)),
            expires: expires
        )
    }

    private func verifier() -> TempoSubscriptionVerifier {
        TempoSubscriptionVerifier()
    }

    // MARK: happy path

    @Test("a credential the client mints verifies and references the challenge")
    func roundTrip() async throws {
        let challenge = try challenge()
        let credential = try await clientMethod().buildCredential(for: challenge)
        let receipt = try await verifier().verify(credential, now: now)
        #expect(receipt.method == challenge.method)
        #expect(receipt.reference == "sub-1")
        #expect(receipt.status == .success)
    }

    // MARK: supports matrix

    @Test("supports a decodable tempo/subscription challenge, rejects others")
    func supports() throws {
        let subject = verifier()
        #expect(try subject.supports(challenge()))
        #expect(try subject.supports(challenge(method: "stripe")) == false)
        #expect(try subject.supports(challenge(intent: "charge")) == false)
    }

    @Test("does not support a malformed request")
    func rejectsMalformed() throws {
        let bad = try Challenge(
            id: "x", realm: realm, method: MethodName("tempo"),
            intent: .subscription, request: EncodedJSON("@@@not-base64@@@")
        )
        #expect(verifier().supports(bad) == false)
    }

    // MARK: reject matrix

    @Test("a challenge with no access key cannot be rebuilt")
    func noAccessKey() async throws {
        // The client supplies a configured key (so it can sign), but the challenge
        // carries none, so the verifier has nothing to reconstruct against.
        let key = try #require(EthereumAddress(hex: Self.requestKeyHex))
        let challenge = try challenge(accessKey: nil)
        let credential = try await clientMethod(
            accessKey: .init(address: key, keyType: .secp256k1)
        ).buildCredential(for: challenge)
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.noAccessKey) {
            _ = try await verifier().verify(credential, now: now)
        }
    }

    @Test("a payload that is not a keyAuthorization is rejected")
    func notAKeyAuthorization() async throws {
        let challenge = try challenge()
        let original = try await clientMethod().buildCredential(for: challenge)
        let tampered = Credential(
            challenge: challenge, source: original.source,
            payload: ["type": .string("proof"), "signature": original.payload["signature"] ?? .null]
        )
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.notAKeyAuthorization) {
            _ = try await verifier().verify(tampered, now: now)
        }
    }

    @Test("a payload with no serialized signature is rejected")
    func missingSerialization() async throws {
        let challenge = try challenge()
        let original = try await clientMethod().buildCredential(for: challenge)
        let tampered = Credential(
            challenge: challenge, source: original.source,
            payload: ["type": .string("keyAuthorization")]
        )
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.missingSerialization) {
            _ = try await verifier().verify(tampered, now: now)
        }
    }

    @Test("a non-hex serialization is rejected as malformed")
    func malformedSerialization() async throws {
        let challenge = try challenge()
        let original = try await clientMethod().buildCredential(for: challenge)
        let tampered = Credential(
            challenge: challenge, source: original.source,
            payload: ["type": .string("keyAuthorization"), "signature": .string("0xZZ")]
        )
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.malformedSerialization) {
            _ = try await verifier().verify(tampered, now: now)
        }
    }

    @Test("an authorization delegating a different access key mismatches")
    func authorizationMismatch() async throws {
        // The client signs over a DIFFERENT access key than the one the server put
        // in the challenge, so the verifier's re-encode-and-compare rejects it.
        let other = try #require(EthereumAddress(hex: Self.recipientHex))
        let challenge = try challenge()
        let credential = try await clientMethod(
            accessKey: .init(address: other, keyType: .secp256k1)
        ).buildCredential(for: challenge)
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.authorizationMismatch) {
            _ = try await verifier().verify(credential, now: now)
        }
    }

    @Test("an expiry that does not outlive the challenge deadline is rejected")
    func expiryNotAfterChallenge() async throws {
        // The challenge deadline is set strictly after the subscription expiry.
        let afterExpiry = Expires(date: Date(timeIntervalSince1970: Self.expiryEpoch + 86400))
        let challenge = try challenge(expires: afterExpiry)
        let credential = try await clientMethod().buildCredential(for: challenge)
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.expiryNotAfterChallenge) {
            _ = try await verifier().verify(credential, now: now)
        }
    }

    @Test("a source naming a different wallet than the signer is rejected")
    func signatureMismatch() async throws {
        let challenge = try challenge()
        let original = try await clientMethod().buildCredential(for: challenge)
        // Same signed authorization, but the source claims a different payer wallet.
        let forged = Credential(
            challenge: challenge,
            source: "did:pkh:eip155:\(Self.chainID):\(Self.recipientHex)",
            payload: original.payload
        )
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.signatureMismatch) {
            _ = try await verifier().verify(forged, now: now)
        }
    }

    @Test("a source on a different chain than the challenge is rejected")
    func chainIdMismatch() async throws {
        let challenge = try challenge()
        let original = try await clientMethod().buildCredential(for: challenge)
        let forged = Credential(
            challenge: challenge,
            source: "did:pkh:eip155:1:\(Self.wallet)",
            payload: original.payload
        )
        await #expect(throws: TempoSubscriptionVerifier.VerifyError.chainIdMismatch) {
            _ = try await verifier().verify(forged, now: now)
        }
    }
}

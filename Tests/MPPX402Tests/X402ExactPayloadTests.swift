import Foundation
import MPPCore
import MPPEVM
import MPPX402
import Testing

// The version-stable x402 "exact" payload wire: the EIP-3009 authorization as JSON (numerics as
// decimal strings, addresses/nonce as 0x-hex, payee key `to`) plus the signed {signature,
// authorization} payload. Round-trips and a pinned wire vector lock the format; the signed payload
// is proven by recovering the signer through the wire.
@Suite("X402 exact payload wire")
struct X402ExactPayloadTests {
    private static let payerKey = Data(repeating: 0, count: 31) + Data([0x01])
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let usdcBaseHex = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Self.payerKey)
    }

    private func payer() throws -> EthereumAddress {
        try #require(EthereumAddress(uncompressedPublicKey: signer().publicKey))
    }

    private func domain() throws -> X402Domain {
        let asset = try #require(EthereumAddress(hex: Self.usdcBaseHex))
        return X402Domain(name: "USD Coin", version: "2", chainId: 8453, asset: asset)
    }

    private func authorization() throws -> X402Authorization {
        let recipient = try #require(EthereumAddress(hex: Self.recipientHex))
        return try #require(X402Authorization(
            from: payer(), recipient: recipient, value: Amount("1000000"),
            validAfter: 0, validBefore: 1_893_456_000, nonce: Data(repeating: 0xAB, count: 32)
        ))
    }

    @Test("an authorization round-trips through its wire form")
    func authorizationRoundTrip() throws {
        let auth = try authorization()
        let recovered = try #require(auth.wire.decoded())
        #expect(recovered == auth)
    }

    @Test("the wire form uses the x402 `to` key and string-typed numerics")
    func wireShape() throws {
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(authorization().wire)
        ) as? [String: Any]
        let object = try #require(json)
        // Payee key is `to`, not `recipient`.
        #expect(object["to"] != nil)
        #expect(object["recipient"] == nil)
        // Numerics are JSON strings, not numbers (x402 avoids number precision loss).
        #expect(object["value"] as? String == "1000000")
        #expect(object["validBefore"] as? String == "1893456000")
        #expect(object["validAfter"] as? String == "0")
        // Addresses are EIP-55 checksummed; the nonce is 0x-hex 32 bytes.
        let fromChecksummed = try payer().checksummed
        #expect(object["from"] as? String == fromChecksummed)
        #expect((object["nonce"] as? String)?.count == 66) // "0x" + 64
    }

    @Test("the wire form is byte-stable (regression, sorted keys)")
    func wireVectorStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(authorization().wire)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == Self.pinnedWireJSON)
    }

    @Test("a signed exact payload recovers the signer through the wire")
    func signedPayloadRecovers() throws {
        let auth = try authorization()
        let domain = try domain()
        let signature = try auth.sign(domain: domain, with: signer())
        let payload = X402ExactPayload(authorization: auth, signature: signature)

        // Round-trip the payload through JSON (as it would travel on the wire).
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(X402ExactPayload.self, from: encoded)

        let sig = try #require(decoded.signatureBytes)
        #expect(sig.count == 65)
        let recoveredAuth = try #require(decoded.authorization.decoded())
        #expect(recoveredAuth == auth)
        #expect(recoveredAuth.isSignedByFrom(domain: domain, signature: sig))
    }

    @Test("a malformed wire authorization decodes to nil (fail-closed)")
    func malformedDecodesToNil() throws {
        let good = try authorization().wire
        func tampered(_ mutate: (inout X402AuthorizationWire) -> Void) -> X402AuthorizationWire {
            var copy = good
            mutate(&copy)
            return copy
        }
        #expect(tampered { $0 = .init(
            from: "not-an-address", recipient: $0.recipient, value: $0.value,
            validAfter: $0.validAfter, validBefore: $0.validBefore, nonce: $0.nonce
        ) }.decoded() == nil)
        #expect(tampered { $0 = .init(
            from: $0.from, recipient: $0.recipient, value: "01", // non-canonical Amount
            validAfter: $0.validAfter, validBefore: $0.validBefore, nonce: $0.nonce
        ) }.decoded() == nil)
        #expect(tampered { $0 = .init(
            from: $0.from, recipient: $0.recipient, value: $0.value,
            validAfter: "-1", validBefore: $0.validBefore, nonce: $0.nonce
        ) }.decoded() == nil)
        #expect(tampered { $0 = .init(
            from: $0.from, recipient: $0.recipient, value: $0.value,
            validAfter: $0.validAfter, validBefore: $0.validBefore,
            nonce: Data(repeating: 0xAB, count: 31).hexPrefixed // 31 bytes, not 32
        ) }.decoded() == nil)
    }

    @Test("signatureBytes requires a 65-byte 0x-hex value")
    func signatureBytesWidth() {
        #expect(X402ExactPayload(
            signature: "0x" + String(repeating: "ab", count: 64), // 64 bytes
            authorization: .init(
                from: "0x0", recipient: "0x0", value: "0", validAfter: "0", validBefore: "0",
                nonce: "0x0"
            )
        ).signatureBytes == nil)
    }

    // Pinned wire JSON (sorted keys) for the fixed authorization above. Locks field names, the `to`
    // key, EIP-55 checksum casing, decimal numerics, and 0x-hex nonce. A change here is a
    // wire-format
    // change.
    private static let pinnedWireJSON =
        #"{"from":"0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf","#
            + #""nonce":"0xabababababababababababababababababababababababababababababababab","#
            + #""to":"0x1111111111111111111111111111111111111111","#
            + #""validAfter":"0","validBefore":"1893456000","value":"1000000"}"#
}

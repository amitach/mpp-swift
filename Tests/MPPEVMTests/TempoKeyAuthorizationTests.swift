import Foundation
import Testing
@testable import MPPEVM

// Golden vectors for the canonical Tempo key-authorization serialization (Tempo Access Keys spec:
// docs.tempo.xyz/protocol/transactions/spec-tempo-transaction#access-keys; RLP per the Ethereum RLP
// spec). A subscription-shaped authorization: access key 0xbe95...cf2c, chainId 42431, expiry
// 1893456000, secp256k1, one weekly limit (1_000_000 base units of 0x20c0...0001 per 604800s), one
// transferWithMemo scope to 0x1111...1111. Signed with private key 0x..01. Byte-exact parity with
// the spec serialization is the bar: the sign payload, the RLP, and the deterministic ECDSA
// signature must all match the canonical encoding.
@Suite("TempoKeyAuthorization: RLP + sign-payload parity with the Tempo spec")
struct TempoKeyAuthorizationTests {
    // The inner authorization tuple (identical in the unsigned + signed serializations) and the
    // 65-byte secp256k1 signature envelope, chunked only to satisfy the line-length limit. The
    // unsigned form is RLP([tuple]) (outer prefix f873); the signed form is RLP([tuple, signature])
    // (outer prefix f8b6 + the b841-prefixed 65-byte signature).
    private let innerTuple =
        "f87182a5bf8094be95c3f554e9fc85ec51be69a3d807a0d55bcf2c8470dbd880dedd"
            + "9420c0000000000000000000000000000000000001830f424083093a80f3f2"
            + "9420c0000000000000000000000000000000000001dcdb8495777d59"
            + "d5941111111111111111111111111111111111111111"
    private let signatureHex =
        "b8412f8b4dba4eea0baaf11a6e6c75ddf3ac45e3884a189f8e0378237693c27caad8"
            + "2401fa516b307698e0c1ddb295b7b919f442dc68658b7357f3d70e2bd51f51d81c"
    private var serializedUnsigned: String {
        "0xf873" + innerTuple
    }

    private var serializedSigned: String {
        "0xf8b6" + innerTuple + signatureHex
    }

    private let signPayloadGolden =
        "0x3a8e031c0d2e5ca1472a8ac5467f9e88164f271a4d1ed5040dbcd2ec83487850"
    private let signerAddress = "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"

    private func fixture() throws -> TempoKeyAuthorization {
        let currency =
            try #require(EthereumAddress(hex: "0x20c0000000000000000000000000000000000001"))
        return try TempoKeyAuthorization(
            address: #require(EthereumAddress(hex: "0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c")),
            chainID: 42431,
            expiry: 1_893_456_000,
            keyType: .secp256k1,
            limits: [.init(token: currency, limit: "1000000", period: 604_800)],
            scopes: [
                .init(
                    address: currency,
                    selector: #require(Data(hexPrefixed: "0x95777d59")),
                    recipients: [
                        #require(
                            EthereumAddress(hex: "0x1111111111111111111111111111111111111111")
                        ),
                    ]
                ),
            ]
        )
    }

    private func signer() throws -> Secp256k1Signer {
        try Secp256k1Signer(privateKey: Data(repeating: 0, count: 31) + Data([1]))
    }

    @Test("unsigned serialization matches the spec RLP golden")
    func unsignedSerialization() throws {
        let expected = try #require(Data(hexPrefixed: serializedUnsigned))
        #expect(try fixture().serialize() == expected)
    }

    @Test("the sign payload is keccak256(RLP(tuple)) per the spec")
    func signPayloadMatches() throws {
        let expected = try #require(Data(hexPrefixed: signPayloadGolden))
        #expect(try fixture().signPayload() == expected)
    }

    @Test("signing produces the deterministic spec signed serialization byte-for-byte")
    func signedSerializationMatches() throws {
        let expected = try #require(Data(hexPrefixed: serializedSigned))
        #expect(try fixture().signedSerialization(with: signer()) == expected)
    }

    @Test("recover returns the signer address from the signed serialization")
    func recoverSigner() throws {
        let serialized = try #require(Data(hexPrefixed: serializedSigned))
        let recovered = try TempoKeyAuthorization.recover(serialized: serialized)
        let expected = try #require(EthereumAddress(hex: signerAddress))
        #expect(recovered == expected)
        // And it equals the address derived from the signer's own public key.
        #expect(try recovered == EthereumAddress(uncompressedPublicKey: signer().publicKey))
    }

    @Test("deserialize round-trips the fields and re-serializes identically")
    func deserializeRoundTrip() throws {
        let serialized = try #require(Data(hexPrefixed: serializedSigned))
        let (authorization, signature) = try TempoKeyAuthorization.deserialize(serialized)
        let original = try fixture()
        #expect(authorization == original)
        #expect(signature?.count == 65)
        #expect(try authorization.serialize(signature: signature) == serialized)
    }

    @Test("an unsigned serialization deserializes with no signature")
    func deserializeUnsigned() throws {
        let serialized = try #require(Data(hexPrefixed: serializedUnsigned))
        let (authorization, signature) = try TempoKeyAuthorization.deserialize(serialized)
        #expect(signature == nil)
        #expect(try authorization == fixture())
    }

    @Test("recover rejects an unsigned or malformed serialization")
    func recoverRejectsUnsigned() throws {
        let unsigned = try #require(Data(hexPrefixed: serializedUnsigned))
        #expect(throws: TempoKeyAuthorization.AuthorizationError.self) {
            try TempoKeyAuthorization.recover(serialized: unsigned)
        }
        #expect(throws: TempoKeyAuthorization.AuthorizationError.self) {
            try TempoKeyAuthorization.recover(serialized: Data([0xC0]))
        }
    }

    @Test("a tampered amount changes the sign payload")
    func tamperChangesPayload() throws {
        var tampered = try fixture()
        tampered.limits = [.init(token: tampered.limits[0].token, limit: "999999", period: 604_800)]
        #expect(try tampered.signPayload() != #require(Data(hexPrefixed: signPayloadGolden)))
    }

    // MARK: Edge shapes mined from the reference test suite (G7.5)

    @Test("two limits serialize to the canonical multi-limit golden and round-trip")
    func multipleLimits() throws {
        let multiLimit =
            "0xf88ff88d82a5bf8094be95c3f554e9fc85ec51be69a3d807a0d55bcf2c8470dbd880"
                + "f839dd9420c0000000000000000000000000000000000001830f424083093a80da"
                + "9420c00000000000000000000000000000000000020583015180f3f2"
                + "9420c0000000000000000000000000000000000001dcdb8495777d59"
                + "d5941111111111111111111111111111111111111111"
        let currency =
            try #require(EthereumAddress(hex: "0x20c0000000000000000000000000000000000001"))
        let currency2 =
            try #require(EthereumAddress(hex: "0x20c0000000000000000000000000000000000002"))
        let auth = try TempoKeyAuthorization(
            address: #require(EthereumAddress(hex: "0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c")),
            chainID: 42431,
            expiry: 1_893_456_000,
            limits: [
                .init(token: currency, limit: "1000000", period: 604_800),
                .init(token: currency2, limit: "5", period: 86400),
            ],
            scopes: [
                .init(
                    address: currency,
                    selector: #require(Data(hexPrefixed: "0x95777d59")),
                    recipients: [
                        #require(
                            EthereumAddress(hex: "0x1111111111111111111111111111111111111111")
                        ),
                    ]
                ),
            ]
        )
        #expect(try auth.serialize() == #require(Data(hexPrefixed: multiLimit)))
        #expect(try TempoKeyAuthorization.deserialize(auth.serialize()).authorization == auth)
    }

    @Test("a zero expiry and a zero chainId encode as empty integers and round-trip")
    func zeroIntegerFields() throws {
        var zeroExpiry = try fixture()
        zeroExpiry.expiry = 0
        var zeroChain = try fixture()
        zeroChain.chainID = 0
        for authorization in [zeroExpiry, zeroChain] {
            let parsed = try TempoKeyAuthorization.deserialize(authorization.serialize())
                .authorization
            #expect(parsed == authorization)
        }
    }

    @Test("an empty key-type tuple field decodes as secp256k1")
    func emptyKeyTypeIsSecp256k1() throws {
        let serialized = try #require(Data(hexPrefixed: serializedSigned))
        #expect(try TempoKeyAuthorization.deserialize(serialized).authorization
            .keyType == .secp256k1)
    }

    @Test("a non-decimal limit amount is rejected as invalidAmount")
    func invalidAmountRejected() throws {
        var bad = try fixture()
        bad.limits = [.init(token: bad.limits[0].token, limit: "not-a-number", period: 604_800)]
        #expect(throws: TempoKeyAuthorization.AuthorizationError.self) { try bad.serialize() }
    }

    @Test("a structurally malformed serialization is rejected")
    func malformedDeserializeRejected() {
        // A 3-element outer list is neither [tuple] nor [tuple, signature].
        let malformed = RLP.encode(.list([.bytes(Data([1])), .bytes(Data([2])), .bytes(Data([3]))]))
        #expect(throws: TempoKeyAuthorization.AuthorizationError.self) {
            try TempoKeyAuthorization.deserialize(malformed)
        }
    }
}

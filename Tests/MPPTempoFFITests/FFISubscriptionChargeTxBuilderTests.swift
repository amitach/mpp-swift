import Foundation
import MPPEVM
import MPPTempo
import Testing
@testable import MPPTempoFFI

/// Proves the SwiftPM integration of the subscription-charge builder: `swift test` links
/// the Rust `tempo-tx-ffi` shim and `FFISubscriptionChargeTxBuilder` produces a `0x76`
/// `transferWithMemo` transaction, attaching the key authorization on the provisioning
/// charge. The same fixed inputs as the Rust test (rust/tempo-tx-ffi/src/lib.rs:
/// `subscription_charge_attaches_key_authorization`), including the peer-serialized golden
/// authorization, so a mismatch on either side trips immediately.
///
/// Gated behind `MPP_TEMPO_FFI` via the Package manifest (the default build pulls zero Rust).
@Suite("FFISubscriptionChargeTxBuilder")
struct FFISubscriptionChargeTxBuilderTests {
    private let chainID: UInt64 = 42431
    private let nonce: UInt64 = 7
    private let accessKey = Data(repeating: 0x02, count: 32)
    private let fee = TempoFeeParameters(
        maxFeePerGas: "1000000000",
        maxPriorityFeePerGas: "1000000",
        gasLimit: 100_000,
        feeToken: nil
    )

    // The reference-serializer (ox/tempo `KeyAuthorization.serialize`, mppx's path) golden
    // signed authorization, shared with the Rust `PEER_GOLDEN_SIGNED_AUTH`.
    private static let peerGoldenAuthHex =
        "f8b6f87182a5bf8094be95c3f554e9fc85ec51be69a3d807a0d55bcf2c8470dbd880dedd9420c00000" +
        "00000000000000000000000000000001830f424083093a80f3f29420c00000000000000000000000000" +
        "00000000001dcdb8495777d59d5941111111111111111111111111111111111111111b8412f8b4dba4e" +
        "ea0baaf11a6e6c75ddf3ac45e3884a189f8e0378237693c27caad82401fa516b307698e0c1ddb295b7b" +
        "919f442dc68658b7357f3d70e2bd51f51d81c"

    private func builder(
        nonceProvider: (@Sendable (EthereumAddress) async throws -> UInt64)? = nil
    ) -> FFISubscriptionChargeTxBuilder {
        FFISubscriptionChargeTxBuilder(
            fee: fee,
            nonceProvider: nonceProvider ?? { [nonce] _ in nonce }
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // The byte-exact no-auth charge tx, shared with the Rust GOLDEN_SUBSCRIPTION_CHARGE_TX.
    private static let goldenCharge =
        "76f8db82a5bf830f4240843b9aca00830186a0f87ef87c9420c0000000000000000000000000000000" +
        "00000180b86495777d590000000000000000000000001111111111111111111111111111111111111111" +
        "00000000000000000000000000000000000000000000000000000000000f4240abababababababababab" +
        "ababababababababababababababababababababababc0800780808080c0b841a4e841b650d9eb291850" +
        "174d5038c4b2488414a8aa0da30acb002b76bd4318a96dd2920e6a9b74346aabc1ccb472923231607" +
        "41ba1678bdc661aba90be3f0bfd1c"

    private func parameters(keyAuthorization: Data?) throws -> TempoSubscriptionChargeParameters {
        try TempoSubscriptionChargeParameters(
            accessKeyPrivateKey: accessKey,
            currency: #require(EthereumAddress(hex: "0x20c0000000000000000000000000000000000001")),
            recipient: #require(EthereumAddress(hex: "0x1111111111111111111111111111111111111111")),
            amount: "1000000",
            memo: Data(repeating: 0xAB, count: 32),
            keyAuthorization: keyAuthorization
        )
    }

    @Test("builds the byte-exact golden 0x76 transferWithMemo charge tx (no key authorization)")
    func chargeWithoutAuthorization() async throws {
        let transaction = try await builder().buildSubscriptionChargeTransaction(
            parameters(keyAuthorization: nil), chainID: chainID
        )
        #expect(transaction.first == 0x76)
        // Identical bytes to the Rust golden (GOLDEN_SUBSCRIPTION_CHARGE_TX), so a mismatch
        // on either side of the FFI trips immediately.
        #expect(hex(transaction) == Self.goldenCharge)
    }

    @Test("the provisioning charge attaches the key authorization (bytes grow)")
    func provisioningChargeAttachesAuthorization() async throws {
        let auth = try #require(Data(hexPrefixed: "0x" + Self.peerGoldenAuthHex))
        let withAuth = try await builder().buildSubscriptionChargeTransaction(
            parameters(keyAuthorization: auth), chainID: chainID
        )
        let withoutAuth = try await builder().buildSubscriptionChargeTransaction(
            parameters(keyAuthorization: nil), chainID: chainID
        )
        #expect(withAuth.first == 0x76)
        #expect(withAuth != withoutAuth)
        #expect(withAuth.count > withoutAuth.count)
    }

    @Test("reads the nonce for the access-key address derived from the per-charge key")
    func nonceProviderReceivesAccessKeyAddress() async throws {
        let signer = try Secp256k1Signer(privateKey: accessKey)
        let expected = try #require(EthereumAddress(uncompressedPublicKey: signer.publicKey))
        let seen = LockedChargeAddress()
        let builder = builder(nonceProvider: { [nonce] address in
            seen.set(address)
            return nonce
        })
        _ = try await builder.buildSubscriptionChargeTransaction(
            parameters(keyAuthorization: nil), chainID: chainID
        )
        #expect(seen.value == expected)
    }

    @Test("an invalid access key surfaces as a typed error, not a crash")
    func invalidAccessKeyThrows() async throws {
        let parameters = try TempoSubscriptionChargeParameters(
            accessKeyPrivateKey: Data(repeating: 0x02, count: 31), // 31 bytes, not 32
            currency: #require(EthereumAddress(hex: "0x20c0000000000000000000000000000000000001")),
            recipient: #require(EthereumAddress(hex: "0x1111111111111111111111111111111111111111")),
            amount: "1000000",
            memo: Data(repeating: 0xAB, count: 32),
            keyAuthorization: nil
        )
        await #expect(throws: FFITempoTxError.invalidSigningKey) {
            _ = try await builder().buildSubscriptionChargeTransaction(parameters, chainID: chainID)
        }
    }
}

/// A tiny `Sendable` box so the `@Sendable` nonce-provider closure can record the address
/// it was handed for the assertion.
private final class LockedChargeAddress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EthereumAddress?
    var value: EthereumAddress? {
        lock.withLock { stored }
    }

    func set(_ address: EthereumAddress) {
        lock.withLock { stored = address }
    }
}

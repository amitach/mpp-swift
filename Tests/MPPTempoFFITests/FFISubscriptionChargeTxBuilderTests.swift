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

    @Test("builds a 0x76 transferWithMemo charge tx without a key authorization")
    func chargeWithoutAuthorization() async throws {
        let transaction = try await builder().buildSubscriptionChargeTransaction(
            parameters(keyAuthorization: nil), chainID: chainID
        )
        #expect(transaction.first == 0x76)
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

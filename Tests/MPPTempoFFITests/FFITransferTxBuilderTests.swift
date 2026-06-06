import Foundation
import MPPEVM
import MPPTempo
import Testing
@testable import MPPTempoFFI

/// Proves the SwiftPM integration of the settled-charge transfer builder: `swift test` links the
/// Rust `tempo-tx-ffi` shim and `FFITransferTxBuilder` produces a `0x76` `transferWithMemo`
/// transaction signed directly by the payer (a plain signature). The same fixed inputs as the Rust
/// test (rust/tempo-tx-ffi/src/lib.rs: `settled_charge_is_a_plain_payer_signed_transfer`), so a
/// mismatch on either side of the FFI trips immediately.
///
/// Gated behind `MPP_TEMPO_FFI` via the Package manifest (the default build pulls zero Rust).
@Suite("FFITransferTxBuilder")
struct FFITransferTxBuilderTests {
    private let chainID: UInt64 = 42431
    private let nonce: UInt64 = 7
    // Account #0's key -> address 0x7e5f...5bdf. The payer signs the transfer directly.
    private let payerKey = Data(repeating: 0x01, count: 32)
    private let payerHex = "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
    private let fee = TempoFeeParameters(
        maxFeePerGas: "1000000000",
        maxPriorityFeePerGas: "1000000",
        gasLimit: 100_000,
        feeToken: nil
    )

    // The byte-exact transfer tx (plain payer signature), shared with the Rust
    // GOLDEN_SETTLED_CHARGE_TX: same payer key, currency, recipient, amount, memo, nonce, and fee.
    // The trailing b841 <65-byte sig> is the plain payer signature (no embedded root address).
    private static let goldenTransfer =
        "76f8db82a5bf830f4240843b9aca00830186a0f87ef87c9420c0000000000000000000000000000000" +
        "00000180b86495777d590000000000000000000000001111111111111111111111111111111111111111" +
        "00000000000000000000000000000000000000000000000000000000000f4240abababababababababab" +
        "ababababababababababababababababababababababc0800780808080c0b841d7b99f66aef71299b88e" +
        "afbde28f651fff83f108f2991e33f7b0df70d4e6b70840330de8ed936d7def1a41d93e67da4a194b0d59" +
        "170ed49763c6a91e2c7501971c"

    private func builder(
        nonceProvider: (@Sendable (EthereumAddress) async throws -> UInt64)? = nil
    ) -> FFITransferTxBuilder {
        FFITransferTxBuilder(fee: fee, nonceProvider: nonceProvider ?? { [nonce] _ in nonce })
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // The pull-mode (expiring-nonce) golden, shared with the Rust GOLDEN_SETTLED_CHARGE_PULL_TX:
    // the a0ffff..ff is the expiring nonce key (U256::MAX), 80 is nonce 0, 8469570a99 is the
    // validBefore (1767312025) the server broadcasts before.
    private static let goldenTransferPull =
        "76f8ff82a5bf830f4240843b9aca00830186a0f87ef87c9420c000000000000000000000000000000000" +
        "000180b86495777d59000000000000000000000000111111111111111111111111111111111111111100" +
        "000000000000000000000000000000000000000000000000000000000f4240ababababababababababab" +
        "abababababababababababababababababababababc0a0ffffffffffffffffffffffffffffffffffffff" +
        "ffffffffffffffffffffffffff808469570a99808080c0b84172b990027d92453d0f99f7cf41614e7de6" +
        "edc371469dcb71a423692b5c65f1cc5c9c403cf1af0ec14b82ec9887277e9c40eeac489089ed6131715b" +
        "a2cef0e9211b"

    private func parameters(
        privateKey: Data? = nil,
        validBefore: UInt64? = nil
    ) throws -> TempoTransferParameters {
        try TempoTransferParameters(
            payerPrivateKey: privateKey ?? payerKey,
            payer: #require(EthereumAddress(hex: payerHex)),
            currency: #require(EthereumAddress(hex: "0x20c0000000000000000000000000000000000001")),
            recipient: #require(EthereumAddress(hex: "0x1111111111111111111111111111111111111111")),
            amount: "1000000",
            memo: Data(repeating: 0xAB, count: 32),
            validBefore: validBefore
        )
    }

    @Test("builds the byte-exact golden 0x76 payer-signed transferWithMemo charge")
    func buildsGoldenTransfer() async throws {
        let transaction = try await builder().buildTransferTransaction(
            parameters(),
            chainID: chainID
        )
        #expect(transaction.first == 0x76)
        #expect(hex(transaction) == Self.goldenTransfer)
    }

    @Test("reads the nonce for the payer account the transfer executes for")
    func nonceProviderReceivesPayer() async throws {
        let expected = try #require(EthereumAddress(hex: payerHex))
        let seen = LockedTransferAddress()
        let builder = builder(nonceProvider: { [nonce] address in
            seen.set(address)
            return nonce
        })
        _ = try await builder.buildTransferTransaction(parameters(), chainID: chainID)
        #expect(seen.value == expected)
    }

    @Test("pull mode builds the byte-exact expiring-nonce charge, without reading the nonce")
    func buildsGoldenPullTransfer() async throws {
        let probed = LockedTransferAddress()
        let builder = builder(nonceProvider: { [nonce] address in
            probed.set(address)
            return nonce
        })
        let transaction = try await builder.buildTransferTransaction(
            parameters(validBefore: 1_767_312_025), chainID: chainID
        )
        #expect(transaction.first == 0x76)
        #expect(hex(transaction) == Self.goldenTransferPull)
        #expect(hex(transaction) != Self.goldenTransfer) // differs from the push tx
        #expect(probed.value == nil) // pull mode does not read a sequential nonce
    }

    @Test("a zero validBefore is rejected (not a usable expiring deadline)")
    func zeroValidBeforeThrows() async throws {
        await #expect(throws: FFITempoTxError.self) {
            _ = try await builder().buildTransferTransaction(
                parameters(validBefore: 0), chainID: chainID
            )
        }
    }

    @Test("an invalid payer key surfaces as a typed error, not a crash")
    func invalidPayerKeyThrows() async throws {
        await #expect(throws: FFITempoTxError.self) {
            _ = try await builder().buildTransferTransaction(
                parameters(privateKey: Data(repeating: 0x01, count: 31)), // 31 bytes, not 32
                chainID: chainID
            )
        }
    }
}

/// A tiny `Sendable` box so the `@Sendable` nonce-provider closure can record the address it was
/// handed for the assertion.
private final class LockedTransferAddress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EthereumAddress?
    var value: EthereumAddress? {
        lock.withLock { stored }
    }

    func set(_ address: EthereumAddress) {
        lock.withLock { stored = address }
    }
}

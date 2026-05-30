import Foundation
import MPPEVM
import MPPTempo
import Testing
@testable import MPPTempoFFI

/// Proves the SwiftPM integration end to end: `swift test` links the Rust
/// `tempo-tx-ffi` shim through the `TempoTxFFI` xcframework binaryTarget, and the
/// `FFITempoCloseTxBuilder` (the `TempoCloseTxBuilder` seam conformer) produces the
/// byte-exact golden `0x76` close transaction. The same fixed inputs as the Rust
/// `close_tx_golden_bytes` test, so a mismatch on either side trips immediately.
///
/// Gated behind the `MPP_TEMPO_FFI` env var via the Package manifest: this whole
/// target only exists (and the xcframework is only built) when the gate is on. The
/// default build pulls zero Rust.
@Suite("FFITempoCloseTxBuilder")
struct FFITempoCloseTxBuilderTests {
    // The fixed inputs shared with the Rust golden test (rust/tempo-tx-ffi/src/lib.rs).
    private let chainID: UInt64 = 42431
    private let nonce: UInt64 = 7
    private let signingKey = Data(repeating: 0x11, count: 32)
    private let fee = TempoFeeParameters(
        maxFeePerGas: "1000000000",
        maxPriorityFeePerGas: "1000000",
        gasLimit: 100_000,
        feeToken: nil
    )

    private func makeEscrow() throws -> EthereumAddress {
        try #require(EthereumAddress(bytes: Data(repeating: 0x55, count: 20)))
    }

    private func makeVoucher() throws -> Voucher {
        try #require(Voucher(
            channelID: Data(repeating: 0xAB, count: 32),
            cumulativeAmount: "1000"
        ))
    }

    // The full signed close tx (351 bytes), byte-identical to the Rust golden vector.
    private static let golden =
        "76f9015b82a5bf830f4240843b9aca00830186a0f8fef8fc94555555555555555555555555555555" +
        "555555555580b8e40d65c51dabababababababababababababababababababababababababababab" +
        "abababab00000000000000000000000000000000000000000000000000000000000003e800000000" +
        "00000000000000000000000000000000000000000000000000000060000000000000000000000000" +
        "00000000000000000000000000000000000000410000000000000000000000000000000000000000" +
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000c0800780" +
        "808080c0b84170186b0fac541ff7fcfcdedd819df35bd3207eae52fdff25b79e1d84ec0cac677365" +
        "daa5efb4e34e307dc760cdeac0a1b95ed8b3129fdfc82764333a0ab6945a1c"

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("produces the byte-exact golden 0x76 close tx through the seam")
    func closeTransactionMatchesGolden() async throws {
        let escrow = try makeEscrow()
        let voucher = try makeVoucher()
        let builder = FFITempoCloseTxBuilder(
            signingKey: signingKey,
            fee: fee,
            nonceProvider: { [nonce] _ in nonce }
        )
        let transaction = try await builder.buildCloseTransaction(
            voucher: voucher,
            signature: Data(repeating: 0, count: 65),
            escrow: escrow,
            chainID: chainID
        )
        #expect(transaction.first == 0x76)
        #expect(hex(transaction) == Self.golden)
    }

    @Test("derives the sender address from the signing key for the nonce lookup")
    func nonceProviderReceivesDerivedSender() async throws {
        // The address the gas-payer key 0x11... derives to (secp256k1 -> Keccak -> low 20).
        let signer = try Secp256k1Signer(privateKey: signingKey)
        let expected = try #require(EthereumAddress(uncompressedPublicKey: signer.publicKey))
        let escrow = try makeEscrow()
        let voucher = try makeVoucher()

        let seen = LockedAddress()
        let builder = FFITempoCloseTxBuilder(
            signingKey: signingKey,
            fee: fee,
            nonceProvider: { [nonce] address in
                seen.set(address)
                return nonce
            }
        )
        _ = try await builder.buildCloseTransaction(
            voucher: voucher,
            signature: Data(repeating: 0, count: 65),
            escrow: escrow,
            chainID: chainID
        )
        #expect(seen.value == expected)
    }

    @Test("an invalid signing key surfaces as a typed error, not a crash")
    func invalidSigningKeyThrows() async throws {
        let escrow = try makeEscrow()
        let voucher = try makeVoucher()
        let builder = FFITempoCloseTxBuilder(
            signingKey: Data(repeating: 0x11, count: 31), // 31 bytes, not 32
            fee: fee,
            nonceProvider: { _ in 0 }
        )
        await #expect(throws: FFITempoTxError.invalidSigningKey) {
            _ = try await builder.buildCloseTransaction(
                voucher: voucher,
                signature: Data(repeating: 0, count: 65),
                escrow: escrow,
                chainID: chainID
            )
        }
    }
}

/// A tiny `Sendable` box so the `@Sendable` nonce-provider closure can record the
/// address it was handed for the assertion (the closure cannot capture a `var`).
private final class LockedAddress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: EthereumAddress?
    var value: EthereumAddress? {
        lock.withLock { stored }
    }

    func set(_ address: EthereumAddress) {
        lock.withLock { stored = address }
    }
}

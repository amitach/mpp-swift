import Foundation
import MPPEVM
import MPPTempo
import Testing
@testable import MPPTempoFFI

/// Proves the SwiftPM integration end to end across all three channel-bookend builders:
/// `swift test` links the Rust `tempo-tx-ffi` shim and `FFITempoTxBuilder` produces the
/// byte-exact golden `0x76` transactions. The same fixed inputs as the Rust golden tests
/// (rust/tempo-tx-ffi/src/lib.rs), so a mismatch on either side trips immediately.
///
/// Gated behind `MPP_TEMPO_FFI` via the Package manifest: this whole target only exists
/// (and the FFI is only built) when the gate is on. The default build pulls zero Rust.
@Suite("FFITempoTxBuilder")
struct FFITempoTxBuilderTests {
    // The fixed inputs shared with the Rust golden tests.
    private let chainID: UInt64 = 42431
    private let nonce: UInt64 = 7
    private let signingKey = Data(repeating: 0x11, count: 32)
    private let fee = TempoFeeParameters(
        maxFeePerGas: "1000000000",
        maxPriorityFeePerGas: "1000000",
        gasLimit: 100_000,
        feeToken: nil
    )

    private func builder() -> FFITempoTxBuilder {
        FFITempoTxBuilder(signingKey: signingKey, fee: fee, nonceProvider: { [nonce] _ in nonce })
    }

    private func address(_ byte: UInt8) throws -> EthereumAddress {
        try #require(EthereumAddress(bytes: Data(repeating: byte, count: 20)))
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("close: byte-exact golden 0x76 tx through the seam")
    func closeMatchesGolden() async throws {
        let voucher = try #require(Voucher(
            channelID: Data(repeating: 0xAB, count: 32),
            cumulativeAmount: "1000"
        ))
        let escrow = try address(0x55)
        let transaction = try await builder().buildCloseTransaction(
            voucher: voucher,
            signature: Data(repeating: 0, count: 65),
            escrow: escrow,
            chainID: chainID
        )
        #expect(transaction.first == 0x76)
        #expect(hex(transaction) == Self.goldenClose)
    }

    @Test("open: byte-exact golden two-call approve + open 0x76 tx")
    func openMatchesGolden() async throws {
        let parameters = try TempoOpenParameters(
            escrow: address(0x55),
            token: address(0x22),
            payee: address(0x33),
            deposit: "1000",
            salt: Data(repeating: 0xAB, count: 32),
            authorizedSigner: address(0x44)
        )
        let transaction = try await builder().buildOpenTransaction(parameters, chainID: chainID)
        #expect(transaction.first == 0x76)
        #expect(hex(transaction) == Self.goldenOpen)
    }

    @Test("topUp: byte-exact golden two-call approve + topUp 0x76 tx")
    func topUpMatchesGolden() async throws {
        let escrow = try address(0x55)
        let token = try address(0x22)
        let transaction = try await builder().buildTopUpTransaction(
            escrow: escrow,
            token: token,
            channelID: Data(repeating: 0xAB, count: 32),
            additionalDeposit: "1000",
            chainID: chainID
        )
        #expect(transaction.first == 0x76)
        #expect(hex(transaction) == Self.goldenTopUp)
    }

    @Test("derives the sender address from the signing key for the nonce lookup")
    func nonceProviderReceivesDerivedSender() async throws {
        let signer = try Secp256k1Signer(privateKey: signingKey)
        let expected = try #require(EthereumAddress(uncompressedPublicKey: signer.publicKey))

        let escrow = try address(0x55)
        let token = try address(0x22)
        let seen = LockedAddress()
        let builder = FFITempoTxBuilder(
            signingKey: signingKey,
            fee: fee,
            nonceProvider: { [nonce] address in
                seen.set(address)
                return nonce
            }
        )
        _ = try await builder.buildTopUpTransaction(
            escrow: escrow,
            token: token,
            channelID: Data(repeating: 0xAB, count: 32),
            additionalDeposit: "1000",
            chainID: chainID
        )
        #expect(seen.value == expected)
    }

    @Test("an invalid signing key surfaces as a typed error, not a crash")
    func invalidSigningKeyThrows() async throws {
        let parameters = try TempoOpenParameters(
            escrow: address(0x55),
            token: address(0x22),
            payee: address(0x33),
            deposit: "1000",
            salt: Data(repeating: 0xAB, count: 32),
            authorizedSigner: address(0x44)
        )
        let builder = FFITempoTxBuilder(
            signingKey: Data(repeating: 0x11, count: 31), // 31 bytes, not 32
            fee: fee,
            nonceProvider: { _ in 0 }
        )
        await #expect(throws: FFITempoTxError.invalidSigningKey) {
            _ = try await builder.buildOpenTransaction(parameters, chainID: chainID)
        }
    }

    private static let goldenClose =
        "76f9015b82a5bf830f4240843b9aca00830186a0f8fef8fc94555555555555555555555555555555" +
        "555555555580b8e40d65c51dabababababababababababababababababababababababababababab" +
        "abababab00000000000000000000000000000000000000000000000000000000000003e800000000" +
        "00000000000000000000000000000000000000000000000000000060000000000000000000000000" +
        "00000000000000000000000000000000000000410000000000000000000000000000000000000000" +
        "00000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000c0800780" +
        "808080c0b84170186b0fac541ff7fcfcdedd819df35bd3207eae52fdff25b79e1d84ec0cac677365" +
        "daa5efb4e34e307dc760cdeac0a1b95ed8b3129fdfc82764333a0ab6945a1c"

    private static let goldenOpen =
        "76f9017a82a5bf830f4240843b9aca00830186a0f9011cf85c942222222222222222222222222222" +
        "22222222222280b844095ea7b3000000000000000000000000555555555555555555555555555555" +
        "555555555500000000000000000000000000000000000000000000000000000000000003e8f8bc94" +
        "555555555555555555555555555555555555555580b8a4c79ea48500000000000000000000000033" +
        "33333333333333333333333333333333333333000000000000000000000000222222222222222222" +
        "22222222222222222222220000000000000000000000000000000000000000000000000000000000" +
        "0003e8abababababababababababababababababababababababababababababababab0000000000" +
        "000000000000004444444444444444444444444444444444444444c0800780808080c0b841de9fb0" +
        "16ce44ed02dca54f29b1ebabe7a64a1a6ac99e83a58cc1adb6cee88d887406777d5e7e3347d60866" +
        "e9569ae234a3faa625ee643ef6986d7115ec1deb591b"

    private static let goldenTopUp =
        "76f9011982a5bf830f4240843b9aca00830186a0f8bcf85c94222222222222222222222222222222" +
        "222222222280b844095ea7b300000000000000000000000055555555555555555555555555555555" +
        "5555555500000000000000000000000000000000000000000000000000000000000003e8f85c9455" +
        "5555555555555555555555555555555555555580b844b67644b9abababababababababababababab" +
        "abababababababababababababababababab00000000000000000000000000000000000000000000" +
        "000000000000000003e8c0800780808080c0b841614b14a310bd2d62e898ea879e38c84dbd59b869" +
        "209c51dd4c261b2eddce322439e6f11f9a4b5678909d4ab9bf29e8052abcb7ab9f6c4518e6455ec5" +
        "d0ae43241b"
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

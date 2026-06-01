import Foundation
import Testing
@testable import MPPEVM

// SignatureEnvelope.canonicalVoucherSignature: the transport-boundary normalizer that strips a
// Tempo 32-byte magic trailer and accepts only a bare 65-byte secp256k1 signature, so the escrow's
// raw `ecrecover` redeems it. Typed envelopes (keychain/p256/webAuthn) are rejected here, and the
// crypto primitive (Voucher.verify) stays canonical-only.
@Suite("SignatureEnvelope")
struct SignatureEnvelopeTests {
    private let chainId: UInt64 = 1
    private let escrow = testAddress("0x5FbDB2315678afecb367f032d93F642f64180aa3")
    private let payer = key1Address
    private let payee = testAddress("0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF")
    private let channelID =
        hexData("2f5fe14977863dd95d0179376a659bbe8f8d26dbf784096cb285b6bc6de8a25d")

    private func signedVoucher() throws -> (Voucher, Data) {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "1000000"))
        let signature = try voucher.sign(
            escrowContract: escrow, chainId: chainId, with: key1Signer()
        )
        #expect(signature.count == 65)
        return (voucher, signature)
    }

    @Test("a bare 65-byte secp256k1 signature passes through unchanged")
    func passesCanonical() throws {
        let (_, signature) = try signedVoucher()
        #expect(SignatureEnvelope.canonicalVoucherSignature(signature) == signature)
    }

    @Test("a magic-suffixed signature is stripped back to the bare 65 bytes")
    func stripsMagicTrailer() throws {
        let (_, signature) = try signedVoucher()
        let withMagic = signature + Data(repeating: 0x77, count: 32)
        #expect(withMagic.count == 97)
        #expect(SignatureEnvelope.canonicalVoucherSignature(withMagic) == signature)
    }

    @Test("a stripped magic-suffixed signature then verifies against the signer")
    func strippedSignatureVerifies() throws {
        let (voucher, signature) = try signedVoucher()
        let withMagic = signature + Data(repeating: 0x77, count: 32)
        let normalized = try #require(SignatureEnvelope.canonicalVoucherSignature(withMagic))
        #expect(voucher.verify(
            escrowContract: escrow, chainId: chainId, signature: normalized, expectedSigner: payer
        ))
    }

    @Test("stripping cannot turn an invalid signature into a valid one")
    func strippingDoesNotForgeValidity() throws {
        // A real, canonical signature, magic-suffixed, normalizes to the bare bytes, but those
        // bytes still recover to the true signer (payer), never to a different expected signer.
        let (voucher, signature) = try signedVoucher()
        let withMagic = signature + Data(repeating: 0x77, count: 32)
        let normalized = try #require(SignatureEnvelope.canonicalVoucherSignature(withMagic))
        #expect(voucher.verify(
            escrowContract: escrow, chainId: chainId, signature: normalized, expectedSigner: payee
        ) == false)
    }

    @Test("a keychain envelope (0x03 prefix) is rejected")
    func rejectsKeychainEnvelope() throws {
        let (_, inner) = try signedVoucher()
        let envelope = Data([0x03]) + payer.bytes + inner // 1 + 20 + 65 = 86 bytes
        #expect(SignatureEnvelope.canonicalVoucherSignature(envelope) == nil)
    }

    @Test("a keychain envelope carrying the magic trailer is still rejected")
    func rejectsKeychainEnvelopeWithMagic() throws {
        let (_, inner) = try signedVoucher()
        let envelope = Data([0x03]) + payer.bytes + inner + Data(repeating: 0x77, count: 32)
        // Strips the trailer to 86 bytes, which is not a bare 65-byte secp256k1, so rejected.
        #expect(SignatureEnvelope.canonicalVoucherSignature(envelope) == nil)
    }

    @Test("a p256-typed envelope (0x01 prefix) is rejected")
    func rejectsTypedEnvelope() {
        let typed = Data([0x01]) + Data(repeating: 0xAB, count: 129)
        #expect(SignatureEnvelope.canonicalVoucherSignature(typed) == nil)
    }

    @Test("a value that is only the 32-byte magic trailer is rejected (not mistaken for empty)")
    func rejectsBareMagicTrailer() {
        let magicOnly = Data(repeating: 0x77, count: 32)
        #expect(SignatureEnvelope.canonicalVoucherSignature(magicOnly) == nil)
    }

    @Test("a 64-byte value ending in the trailer strips to 32 bytes and is rejected")
    func rejectsShortAfterStrip() {
        let value = Data(repeating: 0xAB, count: 32) + Data(repeating: 0x77, count: 32)
        #expect(value.count == 64)
        #expect(SignatureEnvelope.canonicalVoucherSignature(value) == nil)
    }

    @Test("empty, short, and non-65 inputs without a trailer are rejected")
    func rejectsWrongLengths() {
        #expect(SignatureEnvelope.canonicalVoucherSignature(Data()) == nil)
        #expect(SignatureEnvelope
            .canonicalVoucherSignature(Data(repeating: 0x01, count: 64)) == nil)
        #expect(SignatureEnvelope
            .canonicalVoucherSignature(Data(repeating: 0x01, count: 66)) == nil)
    }
}

import Foundation
import MPPEVM
import Testing

// SIG-1-test (audit pin): secp256k1 signature identity is by the RECOVERED ADDRESS, not the raw
// signature bytes. By DEFAULT we do not reject a high-s signature (the EIP-2 malleability twin):
// the malleated signature (s' = n - s with the recovery bit flipped) recovers the SAME address as
// the original, so it authorizes identically. This matches the mppx peer (SIG-1 is documented, not
// rejected by default). A `SignatureMalleabilityPolicy.rejectHighS` opt-in enforces strict EIP-2
// canonical-s; this suite pins both the default and the opt-in.
@Suite("secp256k1 high-s malleability (SIG-1)")
struct Secp256k1MalleabilityTests {
    // The secp256k1 group order n, big-endian.
    private static let order: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    ]

    /// `n - scalar` for a 32-byte big-endian value (with `scalar < n`, which a valid signature's
    /// `s` always is).
    private static func complement(_ scalar: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in stride(from: 31, through: 0, by: -1) {
            let diff = Int(order[index]) - Int(scalar[index]) - borrow
            result[index] = UInt8((diff + 256) % 256)
            borrow = diff < 0 ? 1 : 0
        }
        return result
    }

    /// The high-s malleability twin of a 65-byte wire signature: `s' = n - s`, recovery bit flipped
    /// (`27 <-> 28`). Recovers the same address as the original but is non-canonical (high-s).
    private static func highSTwin(of wire: [UInt8]) -> Data {
        let rBytes = Array(wire[0 ..< 32])
        let twinS = complement(Array(wire[32 ..< 64]))
        let twinV: UInt8 = wire[64] == 27 ? 28 : 27
        return Data(rBytes + twinS + [twinV])
    }

    private func signedTwin(over hash: Data) throws -> (original: Data, twin: Data) {
        let wire = try [UInt8](key1Signer().sign(hash: hash).ethereumWire) // r || s || v, low-s
        return (Data(wire), Self.highSTwin(of: wire))
    }

    @Test("the high-s malleability twin recovers the same address by default (SIG-1)")
    func highSTwinRecoversSameAddress() throws {
        let hash = Data([UInt8](repeating: 0x42, count: 32))
        let (original, twin) = try signedTwin(over: hash)
        // Sanity: the original (low-s) signature recovers the signer's address.
        #expect(EthereumAddress.recover(hash: hash, signature: original) == key1Address)
        #expect(twin != original) // it is genuinely a different signature
        // The high-s twin is NOT rejected and recovers the SAME identity as the original.
        #expect(EthereumAddress.recover(hash: hash, signature: twin) == key1Address)
    }

    @Test("isLowS is true for the canonical signature and false for its high-s twin")
    func isLowSDistinguishesTheTwin() throws {
        let hash = Data([UInt8](repeating: 0x42, count: 32))
        let (original, twin) = try signedTwin(over: hash)
        let originalSig = try #require(RecoverableSignature(ethereumWire: original))
        let twinSig = try #require(RecoverableSignature(ethereumWire: twin))
        #expect(originalSig.isLowS) // libsecp256k1 always emits low-s
        #expect(!twinSig.isLowS)
    }

    @Test("rejectHighS recovers the canonical signature but rejects the high-s twin")
    func rejectHighSGatesTheTwin() throws {
        let hash = Data([UInt8](repeating: 0x42, count: 32))
        let (original, twin) = try signedTwin(over: hash)
        // Default (.accepted) recovers both, exactly as the policy-free recover does.
        #expect(EthereumAddress.recover(hash: hash, signature: twin, malleability: .accepted)
            == key1Address)
        // rejectHighS recovers the canonical low-s one, rejects the high-s twin.
        #expect(EthereumAddress.recover(hash: hash, signature: original, malleability: .rejectHighS)
            == key1Address)
        #expect(EthereumAddress.recover(hash: hash, signature: twin, malleability: .rejectHighS)
            == nil)
    }

    @Test("Voucher.verify honors rejectHighS on the voucher verify path")
    func voucherVerifyGatesHighS() throws {
        let escrow = testAddress("0x5FbDB2315678afecb367f032d93F642f64180aa3")
        let chainId: UInt64 = 1
        let voucher = try #require(
            Voucher(channelID: Data(repeating: 0xAB, count: 32), cumulativeAmount: "1000")
        )
        let (original, twin) = try signedTwin(
            over: voucher.signingHash(escrowContract: escrow, chainId: chainId)
        )
        func verify(_ sig: Data, _ policy: SignatureMalleabilityPolicy) -> Bool {
            voucher.verify(
                escrowContract: escrow, chainId: chainId, signature: sig,
                expectedSigner: key1Address, malleability: policy
            )
        }
        #expect(verify(original, .rejectHighS)) // canonical accepted
        #expect(!verify(twin, .rejectHighS)) // high-s twin rejected
        #expect(verify(twin, .accepted)) // but accepted under the default (peer behavior)
    }

    @Test("ZeroAmountProof.recoverSigner honors rejectHighS on the proof verify path")
    func proofRecoverGatesHighS() throws {
        let chainId: UInt64 = 1
        let proof = ZeroAmountProof.v2Realm(challengeId: "c1", realm: "api.example.com")
        let (original, twin) = try signedTwin(over: proof.signingHash(chainId: chainId))
        #expect(proof.recoverSigner(
            chainId: chainId,
            signature: original,
            malleability: .rejectHighS
        )
            == key1Address)
        #expect(proof.recoverSigner(chainId: chainId, signature: twin, malleability: .rejectHighS)
            == nil)
        #expect(proof.recoverSigner(chainId: chainId, signature: twin, malleability: .accepted)
            == key1Address)
    }
}

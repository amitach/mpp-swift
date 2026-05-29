import Foundation
import Testing
@testable import MPPKeccak

// secp256k1 recoverable ECDSA over a raw 32-byte hash, via Bitcoin Core's
// libsecp256k1. RFC 6979 deterministic nonce (so signatures are reproducible)
// and low-s by construction. Byte-exact EIP-712 golden vectors land with the
// EIP-712 layer (PR-2); here we pin the primitive's self-consistency.
@Suite("Secp256k1Signer")
struct Secp256k1SignerTests {
    // A fixed, valid 32-byte private key (0x01) and a fixed 32-byte message hash.
    private func key() -> Data {
        Data([UInt8](repeating: 0, count: 31) + [1])
    }

    private func hash() -> Data {
        Data((0 ..< 32).map { UInt8($0) })
    }

    @Test("a 32-byte hash signs to a 64-byte compact signature + recovery id")
    func signsToRecoverableForm() throws {
        let signature = try Secp256k1Signer(privateKey: key()).sign(hash: hash())
        #expect(signature.compact.count == 64)
        #expect(signature.recoveryID <= 3)
        #expect(signature.serialized.count == 65)
    }

    @Test("the recovered public key matches the signer's (sign -> recover round-trip)")
    func recoverRoundTrip() throws {
        let signer = try Secp256k1Signer(privateKey: key())
        let signature = try signer.sign(hash: hash())
        let recovered = Secp256k1Signer.recoverPublicKey(hash: hash(), signature: signature)
        #expect(recovered == signer.publicKey)
        #expect(signer.publicKey.count == 65)
        #expect(signer.publicKey.first == 0x04) // uncompressed prefix
    }

    @Test("signing is deterministic (RFC 6979): same key + hash yields the same signature")
    func deterministic() throws {
        let signer = try Secp256k1Signer(privateKey: key())
        let first = try signer.sign(hash: hash())
        let second = try signer.sign(hash: hash())
        #expect(first == second)
    }

    @Test("a different hash yields a different signature")
    func differentHashDiffersSignature() throws {
        let signer = try Secp256k1Signer(privateKey: key())
        let forward = try signer.sign(hash: hash())
        let reversed = try signer.sign(hash: Data((0 ..< 32).map { UInt8(31 - $0) }))
        #expect(forward != reversed)
    }

    @Test("an invalid key length is rejected")
    func rejectsBadKeyLength() {
        #expect(throws: Secp256k1Signer.KeyError.invalidLength) {
            try Secp256k1Signer(privateKey: Data([1, 2, 3]))
        }
    }

    @Test("an all-zero key (not a valid scalar) is rejected")
    func rejectsZeroKey() {
        #expect(throws: Secp256k1Signer.KeyError.invalidKey) {
            try Secp256k1Signer(privateKey: Data(repeating: 0, count: 32))
        }
    }

    @Test("a non-32-byte hash is rejected")
    func rejectsBadHashLength() throws {
        let signer = try Secp256k1Signer(privateKey: key())
        #expect(throws: Secp256k1Signer.SigningError.invalidHashLength) {
            try signer.sign(hash: Data([1, 2, 3]))
        }
    }
}

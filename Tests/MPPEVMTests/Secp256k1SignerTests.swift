import Foundation
import Testing
@testable import MPPEVM

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

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
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

    // Golden vector cross-checked against @noble/curves (an independent secp256k1
    // RFC-6979 + low-s implementation) signing the RAW hash (noble `prehash: false`):
    // signing key=1 over hash 0x00...1f must yield this exact compact r||s, recovery
    // 1, and public key (= the generator G). This pins that the signer signs the hash
    // directly (no extra SHA-256), which is required for EIP-712.
    @Test("matches an independent RFC-6979 + low-s golden vector (raw-hash signing)")
    func goldenVector() throws {
        let signer = try Secp256k1Signer(privateKey: key())
        let signature = try signer.sign(hash: hash())
        let expectedR = "a951b0cf98bd51c614c802a65a418fa42482dc5c45c9394e39c0d98773c51cd5"
        let expectedS = "30104fdc36d91582b5757e1de73d982e803cc14d75e82c65daf924e38d27d834"
        #expect(hex(signature.compact) == expectedR + expectedS)
        #expect(signature.recoveryID == 1)
        // The public key for private key 1 is the secp256k1 generator G, serialized
        // uncompressed as 0x04 || G.x || G.y (each coordinate 32 bytes).
        let generatorX = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        let generatorY = "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"
        #expect(hex(signer.publicKey) == "04" + generatorX + generatorY)
    }

    // Blocker fixes: recoverPublicKey is the attacker-facing verification path.
    // A malformed signature must return nil, never abort the process or read out
    // of bounds. The unchecked initializer bypasses validation to reach the guard.
    @Test("recoverPublicKey returns nil (never aborts) on an out-of-range recovery id")
    func recoverRejectsBadRecoveryID() {
        let signature = RecoverableSignature(
            unchecked: Data(repeating: 0, count: 64),
            recoveryID: 200
        )
        #expect(Secp256k1Signer.recoverPublicKey(hash: hash(), signature: signature) == nil)
    }

    @Test("recoverPublicKey returns nil (never overreads) on a short compact buffer")
    func recoverRejectsShortCompact() {
        let signature = RecoverableSignature(unchecked: Data([1, 2, 3]), recoveryID: 0)
        #expect(Secp256k1Signer.recoverPublicKey(hash: hash(), signature: signature) == nil)
    }

    @Test("RecoverableSignature enforces its 64-byte / 0...3 invariant at construction")
    func signatureInitValidates() {
        #expect(RecoverableSignature(compact: Data(repeating: 0, count: 63), recoveryID: 0) == nil)
        #expect(RecoverableSignature(compact: Data(repeating: 0, count: 64), recoveryID: 4) == nil)
        #expect(RecoverableSignature(compact: Data(repeating: 0, count: 64), recoveryID: 0) != nil)
    }
}

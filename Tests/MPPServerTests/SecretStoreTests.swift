import Foundation
import MPPCore
import MPPServer
import Testing

// SecretStore validation + rotate-with-overlap (the MPP security guidance): a
// challenge minted under the previous key still verifies during the overlap
// window, and stops once the key is dropped.
@Suite("SecretStore")
struct SecretStoreTests {
    // Distinct >= 32-byte keys (the HMAC-SHA256 minimum SecretStore enforces).
    private let keyA = Data(repeating: 0xA1, count: 32)
    private let keyB = Data(repeating: 0xB2, count: 32)
    private let keyC = Data(repeating: 0xC3, count: 32)

    private func draft() throws -> Challenge {
        try Challenge(
            id: "unsigned", realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30")
        )
    }

    /// A challenge with its id minted under `secret`.
    private func minted(under secret: Data) throws -> Challenge {
        let unsigned = try draft()
        return unsigned.withID(ChallengeSigner(secret: secret).computeID(for: unsigned))
    }

    // MARK: validation

    @Test("accepts >= 32-byte current and previous keys")
    func acceptsValidKeys() throws {
        #expect(throws: Never.self) { try SecretStore(current: keyA, previous: [keyB, keyC]) }
    }

    @Test("rejects a short or empty current key")
    func rejectsShortCurrent() {
        #expect(throws: SecretStore.ValidationError.tooShort(byteCount: 16)) {
            try SecretStore(current: Data(repeating: 1, count: 16))
        }
        #expect(throws: SecretStore.ValidationError.tooShort(byteCount: 0)) {
            try SecretStore(current: Data())
        }
    }

    @Test("rejects a short previous key (the whole set is validated)")
    func rejectsShortPrevious() {
        #expect(throws: SecretStore.ValidationError.tooShort(byteCount: 8)) {
            try SecretStore(current: keyA, previous: [Data(repeating: 9, count: 8)])
        }
    }

    @Test("accepts a key exactly at the maximum but rejects one over it (sanity bound)")
    func enforcesMaximumLength() {
        let max = SecretStore.maximumSecretBytes
        #expect(throws: Never.self) { try SecretStore(current: Data(repeating: 1, count: max)) }
        #expect(throws: SecretStore.ValidationError.tooLong(byteCount: max + 1)) {
            try SecretStore(current: Data(repeating: 1, count: max + 1))
        }
        // The whole set is validated, so an over-long previous key is rejected too.
        #expect(throws: SecretStore.ValidationError.tooLong(byteCount: max + 1)) {
            try SecretStore(current: keyA, previous: [Data(repeating: 2, count: max + 1)])
        }
    }

    @Test("rejects more than the maximum previous keys (DoS bound)")
    func rejectsTooManyPreviousKeys() {
        let max = SecretStore.maximumPreviousKeys
        // At the cap: accepted. One over: rejected.
        let atCap = Array(repeating: keyB, count: max)
        #expect(throws: Never.self) { try SecretStore(current: keyA, previous: atCap) }
        #expect(throws: SecretStore.ValidationError.tooManyPreviousKeys(count: max + 1)) {
            try SecretStore(current: keyA, previous: Array(repeating: keyB, count: max + 1))
        }
    }

    // MARK: rotation

    @Test("a challenge minted under the previous key verifies during the overlap window")
    func previousKeyVerifiesDuringOverlap() throws {
        // Rotated to B, with A still in its overlap window.
        let rotated = try ChallengeSigner(secretStore: SecretStore(current: keyB, previous: [keyA]))
        let underA = try minted(under: keyA)
        let underB = try minted(under: keyB)
        #expect(rotated.verify(underA)) // previous key
        #expect(rotated.verify(underB)) // current key
    }

    @Test("once the previous key is dropped, its challenges no longer verify")
    func droppedKeyStopsVerifying() throws {
        let afterDrop = try ChallengeSigner(secretStore: SecretStore(current: keyB))
        let underA = try minted(under: keyA)
        let underB = try minted(under: keyB)
        #expect(afterDrop.verify(underB))
        #expect(afterDrop.verify(underA) == false)
    }

    @Test("a challenge minted under an unknown key never verifies")
    func unknownKeyRejected() throws {
        let signer = try ChallengeSigner(secretStore: SecretStore(current: keyB, previous: [keyA]))
        let underC = try minted(under: keyC)
        #expect(signer.verify(underC) == false)
    }

    @Test("minting always uses the current key, never a previous one")
    func mintUsesCurrent() throws {
        let signer = try ChallengeSigner(secretStore: SecretStore(current: keyB, previous: [keyA]))
        let unsigned = try draft()
        #expect(signer.computeID(for: unsigned)
            == ChallengeSigner(secret: keyB).computeID(for: unsigned))
        #expect(signer.computeID(for: unsigned)
            != ChallengeSigner(secret: keyA).computeID(for: unsigned))
    }
}

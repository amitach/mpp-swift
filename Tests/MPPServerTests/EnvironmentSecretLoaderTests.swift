import Foundation
import MPPCore
import MPPServer
import Testing

// Loads a SecretStore from an injected environment (the spec's env-delivery
// mechanism). The secret is the variable value's UTF-8 bytes, so a loaded key
// produces the same HMAC id as ChallengeSigner(secret: Data(value.utf8)).
@Suite("EnvironmentSecretLoader")
struct EnvironmentSecretLoaderTests {
    // 32+ ASCII chars => 32+ UTF-8 bytes, satisfying SecretStore's minimum.
    private let currentValue = String(repeating: "c", count: 32)
    private let previousValue = String(repeating: "p", count: 32)

    private func draft() throws -> Challenge {
        try Challenge(
            id: "unsigned", realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30")
        )
    }

    @Test("loads the current key alone")
    func loadsCurrentOnly() throws {
        let store = try EnvironmentSecretLoader.load(from: ["MPP_SECRET_KEY": currentValue])
        let signer = ChallengeSigner(secretStore: store)
        let minted = try draft()
        // Byte-compatible with the raw-string HMAC key.
        #expect(signer.computeID(for: minted)
            == ChallengeSigner(secret: Data(currentValue.utf8)).computeID(for: minted))
    }

    @Test("loads current + comma-separated previous keys (rotation)")
    func loadsPreviousKeys() throws {
        let store = try EnvironmentSecretLoader.load(from: [
            "MPP_SECRET_KEY": currentValue,
            "MPP_SECRET_KEY_PREVIOUS": " \(previousValue) , \(String(repeating: "q", count: 32)) ",
        ])
        let rotated = ChallengeSigner(secretStore: store)
        let unsigned = try draft()
        // A challenge minted under the previous key still verifies.
        let underPrevious = unsigned.withID(
            ChallengeSigner(secret: Data(previousValue.utf8)).computeID(for: unsigned)
        )
        #expect(rotated.verify(underPrevious))
    }

    @Test("an empty MPP_SECRET_KEY_PREVIOUS yields no previous keys")
    func emptyPreviousIsIgnored() throws {
        let store = try EnvironmentSecretLoader.load(from: [
            "MPP_SECRET_KEY": currentValue,
            "MPP_SECRET_KEY_PREVIOUS": "",
        ])
        let signer = ChallengeSigner(secretStore: store)
        let unsigned = try draft()
        let underOther = unsigned.withID(
            ChallengeSigner(secret: Data(previousValue.utf8)).computeID(for: unsigned)
        )
        #expect(signer.verify(underOther) == false)
    }

    @Test("a missing or empty current key throws missingSecret")
    func missingCurrentThrows() {
        #expect(throws: EnvironmentSecretLoader.LoadError
            .missingSecret(variable: "MPP_SECRET_KEY")) {
            try EnvironmentSecretLoader.load(from: [:])
        }
        #expect(throws: EnvironmentSecretLoader.LoadError
            .missingSecret(variable: "MPP_SECRET_KEY")) {
            try EnvironmentSecretLoader.load(from: ["MPP_SECRET_KEY": ""])
        }
    }

    @Test("a too-short key surfaces the SecretStore validation error")
    func shortKeySurfacesValidation() {
        #expect(throws: EnvironmentSecretLoader.LoadError.invalid(.tooShort(byteCount: 5))) {
            try EnvironmentSecretLoader.load(from: ["MPP_SECRET_KEY": "short"])
        }
    }

    @Test("a too-long key surfaces the SecretStore validation error")
    func longKeySurfacesValidation() {
        let overMax = SecretStore.maximumSecretBytes + 1
        let value = String(repeating: "k", count: overMax) // ASCII => overMax UTF-8 bytes
        #expect(throws: EnvironmentSecretLoader.LoadError.invalid(.tooLong(byteCount: overMax))) {
            try EnvironmentSecretLoader.load(from: ["MPP_SECRET_KEY": value])
        }
    }
}

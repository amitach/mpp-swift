import Foundation
import MPPCore
import MPPServer
import Testing

// Loads a SecretStore from secret files (the spec's managed-store injection model,
// delivered as mounted files). The file's exact bytes are the HMAC key, with no
// trimming, so a loaded key produces the same id as ChallengeSigner(secret: bytes)
// and matches EnvironmentSecretLoader for the same secret.
@Suite("FileSecretLoader")
final class FileSecretLoaderTests: Sendable {
    private let root: URL
    private let currentBytes = Data(repeating: 0x63, count: 32) // 32 'c'
    private let previousBytes = Data(repeating: 0x70, count: 32) // 32 'p'

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpp-secret-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Writes `bytes` to a fresh file and returns its path.
    private func writeFile(_ bytes: Data) -> String {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: false)
        FileManager.default.createFile(atPath: url.path, contents: bytes)
        return url.path
    }

    private func draft() throws -> Challenge {
        try Challenge(
            id: "unsigned", realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30")
        )
    }

    @Test("loads the current key alone, using the file's exact bytes")
    func loadsCurrentOnly() throws {
        let store = try FileSecretLoader.load(currentPath: writeFile(currentBytes))
        let signer = ChallengeSigner(secretStore: store)
        let minted = try draft()
        #expect(signer.computeID(for: minted)
            == ChallengeSigner(secret: currentBytes).computeID(for: minted))
    }

    @Test("loads current + previous key files (rotation)")
    func loadsPreviousKeys() throws {
        let otherPrevious = Data(repeating: 0x71, count: 32) // 32 'q'
        let store = try FileSecretLoader.load(
            currentPath: writeFile(currentBytes),
            previousPaths: [writeFile(previousBytes), writeFile(otherPrevious)]
        )
        let rotated = ChallengeSigner(secretStore: store)
        let unsigned = try draft()
        // A challenge minted under a previous key still verifies.
        let underPrevious = unsigned.withID(
            ChallengeSigner(secret: previousBytes).computeID(for: unsigned)
        )
        #expect(rotated.verify(underPrevious))
    }

    @Test("reads a raw binary key verbatim, not as decoded text")
    func loadsRawBinaryKey() throws {
        let binary = Data((0 ..< 32).map { UInt8($0) }) // non-UTF8-text bytes
        let store = try FileSecretLoader.load(currentPath: writeFile(binary))
        let signer = ChallengeSigner(secretStore: store)
        let minted = try draft()
        #expect(signer.computeID(for: minted)
            == ChallengeSigner(secret: binary).computeID(for: minted))
    }

    @Test("does not trim a trailing newline: the bytes are used exactly")
    func doesNotTrimTrailingNewline() throws {
        // A file written with a trailing newline is a different key from the same
        // bytes without it; the loader must not silently strip it.
        let withNewline = currentBytes + Data([0x0A])
        let store = try FileSecretLoader.load(currentPath: writeFile(withNewline))
        let signer = ChallengeSigner(secretStore: store)
        let minted = try draft()
        #expect(signer.computeID(for: minted)
            == ChallengeSigner(secret: withNewline).computeID(for: minted))
        #expect(signer.computeID(for: minted)
            != ChallengeSigner(secret: currentBytes).computeID(for: minted))
    }

    @Test("a missing current file throws unreadable")
    func missingCurrentThrows() {
        let path = root.appendingPathComponent("does-not-exist").path
        #expect(throws: FileSecretLoader.LoadError.unreadable(path: path)) {
            try FileSecretLoader.load(currentPath: path)
        }
    }

    @Test("a missing previous file throws unreadable")
    func missingPreviousThrows() throws {
        let current = writeFile(currentBytes)
        let missing = root.appendingPathComponent("no-previous").path
        #expect(throws: FileSecretLoader.LoadError.unreadable(path: missing)) {
            try FileSecretLoader.load(currentPath: current, previousPaths: [missing])
        }
    }

    @Test("an empty current file surfaces the too-short validation error")
    func emptyCurrentSurfacesValidation() {
        #expect(throws: FileSecretLoader.LoadError.invalid(.tooShort(byteCount: 0))) {
            try FileSecretLoader.load(currentPath: writeFile(Data()))
        }
    }

    @Test("a too-short key surfaces the SecretStore validation error")
    func shortKeySurfacesValidation() {
        #expect(throws: FileSecretLoader.LoadError.invalid(.tooShort(byteCount: 5))) {
            try FileSecretLoader.load(currentPath: writeFile(Data(repeating: 0x61, count: 5)))
        }
    }

    @Test("too many previous keys surfaces the SecretStore validation error")
    func tooManyPreviousSurfacesValidation() {
        let nine = (0 ..< 9).map { _ in writeFile(previousBytes) }
        #expect(throws: FileSecretLoader.LoadError.invalid(.tooManyPreviousKeys(count: 9))) {
            try FileSecretLoader.load(currentPath: writeFile(currentBytes), previousPaths: nine)
        }
    }

    @Test("a file at the maximum length loads; one over it is rejected by size")
    func enforcesMaximumLength() {
        let max = SecretStore.maximumSecretBytes
        #expect(throws: Never.self) {
            try FileSecretLoader.load(currentPath: writeFile(Data(repeating: 0x61, count: max)))
        }
        // The over-long file is rejected by its size, before being read into memory.
        #expect(throws: FileSecretLoader.LoadError.invalid(.tooLong(byteCount: max + 1))) {
            try FileSecretLoader.load(currentPath: writeFile(Data(repeating: 0x61, count: max + 1)))
        }
    }
}

import Foundation
import Testing
@testable import MPPCore

// The transparent single-value `Codable` (encode as a bare JSON string,
// re-validate on decode) and `description == rawValue` are provided once by the
// `RawStringValidated` protocol. This suite proves that shared mechanism for
// every conformer in one place rather than re-proving it per type.

/// Asserts that a `RawStringValidated` value encodes as the given bare JSON
/// string, round-trips through `Codable`, and describes itself as its raw value.
private func assertTransparent<T: RawStringValidated>(_ value: T, encodesAs json: String) throws {
    let data = try JSONEncoder().encode(value)
    #expect(String(bytes: data, encoding: .utf8) == json)
    #expect(try JSONDecoder().decode(T.self, from: data) == value)
    #expect(String(describing: value) == value.rawValue)
}

@Suite("RawStringValidated")
struct RawStringValidatedTests {
    @Test("each conformer encodes as a single JSON string and round-trips")
    func transparentCodable() throws {
        try assertTransparent(MethodName("tempo"), encodesAs: "\"tempo\"")
        try assertTransparent(IntentName.charge, encodesAs: "\"charge\"")
        try assertTransparent(Amount("1000000"), encodesAs: "\"1000000\"")
        try assertTransparent(
            Expires("2026-01-01T00:00:00Z"),
            encodesAs: "\"2026-01-01T00:00:00Z\""
        )
        try assertTransparent(EncodedJSON("abc123"), encodesAs: "\"abc123\"")
        try assertTransparent(
            RFC3339DateTime("2026-01-02T03:04:05Z"),
            encodesAs: "\"2026-01-02T03:04:05Z\""
        )
    }

    @Test("decoding an invalid raw value throws a DecodingError")
    func decodeRejectsInvalid() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MethodName.self, from: Data("\"TEMPO\"".utf8))
        }
    }
}

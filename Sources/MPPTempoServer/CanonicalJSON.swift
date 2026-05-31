import Foundation

/// Encodes a value to canonical JSON text: sorted keys and unescaped slashes, the
/// stable form the session stream and WebSocket-frame codecs emit on the wire.
enum CanonicalJSON {
    /// The canonical JSON string for `value`.
    ///
    /// - Throws: ``EncodingError`` if encoding fails or the bytes are not UTF-8 (not
    ///   expected for the codecs' value types).
    static func string(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: [], debugDescription: "JSON encoding was not valid UTF-8"
            ))
        }
        return string
    }
}

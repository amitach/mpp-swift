import Foundation

/// JSON carried on the wire as base64url(JCS(json)): the form the MPP challenge
/// `request` and `opaque` parameters use.
///
/// Per `draft-payment-intent-charge-00`, the value is JCS-serialized (RFC 8785)
/// then base64url-encoded without padding. The encoded string is preserved
/// **verbatim** in ``rawValue`` because the challenge-id HMAC binds the literal
/// `request` / `opaque` value; re-encoding it (re-sorting keys, changing string
/// escaping) would change the bytes and break the binding. Decode on demand;
/// never round-trip a received value through a re-encode.
public struct EncodedJSON: Sendable, Hashable {
    /// The base64url-encoded JSON exactly as it appears on the wire.
    public let rawValue: String

    /// Wraps an already-encoded value, preserving it verbatim.
    ///
    /// Used when parsing a value off the wire. The string is not validated as
    /// base64url here, so the binding always sees exactly what was received;
    /// ``decodedData()`` reports a malformed encoding when the value is read.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Encodes a ``JSONValue`` as base64url(JCS(value)), for minting a challenge.
    public init(json: JSONValue) {
        rawValue = Base64URL.encode(Data(json.canonicalized().utf8))
    }

    /// The decoded JSON bytes.
    ///
    /// - Throws: ``Base64URL/DecodeError`` if ``rawValue`` is not valid
    ///   unpadded base64url.
    public func decodedData() throws(Base64URL.DecodeError) -> Data {
        try Base64URL.decode(rawValue)
    }
}

// Transparent Codable + description come from RawStringValidated. The validating
// initializer is non-throwing (a received value is preserved verbatim), which
// satisfies the protocol's throwing requirement.
extension EncodedJSON: RawStringValidated {}

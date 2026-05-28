import Crypto
import Foundation

/// Encoder, parser, and verifier for the RFC 9530 `Content-Digest` used by the
/// MPP challenge `digest` parameter.
///
/// Per `draft-httpauth-payment-00` §5.1, `digest` is an RFC 9530 Content-Digest
/// of the request body, for example
/// `sha-256=:X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE=:`. MPP uses SHA-256.
/// The value is an RFC 8941 structured-field dictionary whose member value is a
/// byte sequence: standard base64 **with** padding, delimited by colons.
public enum ContentDigest {
    /// The digest algorithm MPP uses (`draft-httpauth-payment-00` §5.1).
    public static let algorithm = "sha-256"

    /// The RFC 9530 Content-Digest value for `body`: `sha-256=:<base64>:`.
    public static func compute(_ body: Data) -> String {
        let digest = Data(SHA256.hash(data: body))
        return "\(algorithm)=:\(digest.base64EncodedString()):"
    }

    /// Whether `body` matches the `sha-256` digest in an RFC 9530 Content-Digest
    /// header value.
    ///
    /// A plain comparison is correct here: the content digest is public integrity
    /// data, not a keyed MAC, and the expected digest travels in the header, so
    /// no secret's compare time can leak. (Constant-time comparison is reserved
    /// for the keyed challenge-id HMAC.)
    ///
    /// - Throws: ``ParseError`` if the value is malformed or carries no `sha-256`
    ///   member.
    public static func verify(
        _ body: Data,
        matches headerValue: String
    ) throws(ParseError) -> Bool {
        let members = try parse(headerValue)
        guard let expected = members[algorithm] else { throw .missingAlgorithm }
        return Data(SHA256.hash(data: body)) == expected
    }

    /// Parses an RFC 9530 Content-Digest value into its `algorithm -> bytes`
    /// members. Each member is `key=:base64:`; multiple members are comma-
    /// separated. Keys are lower-cased; member order is irrelevant.
    static func parse(_ headerValue: String) throws(ParseError) -> [String: Data] {
        var members: [String: Data] = [:]
        for element in headerValue.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = element.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            // The first '=' separates the key from the value; base64 padding '='
            // only ever appears inside the value, after the leading colon.
            guard let separator = piece.firstIndex(of: "=") else { throw .malformed(piece) }
            let key = piece[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = piece[piece.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw .malformed(piece) }
            guard value.count >= 2, value.hasPrefix(":"), value.hasSuffix(":") else {
                throw .malformed(piece)
            }
            let base64 = String(value.dropFirst().dropLast())
            guard let bytes = Data(base64Encoded: base64) else { throw .invalidBase64(base64) }
            members[key] = bytes
        }
        return members
    }

    /// A reason an RFC 9530 Content-Digest value could not be parsed.
    public enum ParseError: Error, Sendable, Hashable {
        /// A member was not of the form `key=:base64:`.
        case malformed(String)
        /// A member's byte sequence was not valid base64.
        case invalidBase64(String)
        /// No `sha-256` member was present to verify against.
        case missingAlgorithm
    }
}

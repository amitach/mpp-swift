import Foundation

/// base64url codec without padding, per RFC 4648 §5.
///
/// The MPP wire format uses base64url **without padding** for the challenge
/// `request` field and credential payloads (`draft-payment-intent-charge-00`:
/// "serialized using JCS and base64url-encoded without padding"). Foundation
/// only provides standard base64 (`+`, `/`, `=`), so this type translates to
/// and from the URL-safe, unpadded alphabet.
///
/// Decoding is strict: only `A`–`Z`, `a`–`z`, `0`–`9`, `-`, and `_` are
/// accepted. Standard-base64 input (`+`, `/`, or `=` padding) is rejected, so a
/// non-conforming peer is caught rather than silently accepted.
public enum Base64URL {
    /// Encodes bytes as an unpadded base64url string.
    public static func encode(_ data: Data) -> String {
        var encoded = data.base64EncodedString()
        encoded = encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        if let padding = encoded.firstIndex(of: "=") {
            encoded = String(encoded[..<padding])
        }
        return encoded
    }

    /// Decodes an unpadded base64url string to bytes.
    ///
    /// - Throws: ``DecodeError`` for any character outside the base64url
    ///   alphabet, an impossible length, or otherwise invalid encoding.
    public static func decode(_ string: String) throws(DecodeError) -> Data {
        for scalar in string.unicodeScalars where !isBase64URLScalar(scalar.value) {
            throw .invalidCharacter
        }
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch standard.count % 4 {
        case 0: break
        case 2: standard += "=="
        case 3: standard += "="
        default: throw .invalidLength
        }
        guard let data = Data(base64Encoded: standard) else {
            throw .invalidEncoding
        }
        return data
    }

    private static func isBase64URLScalar(_ value: UInt32) -> Bool {
        (0x41 ... 0x5A).contains(value) // A-Z
            || (0x61 ... 0x7A).contains(value) // a-z
            || (0x30 ... 0x39).contains(value) // 0-9
            || value == 0x2D // "-"
            || value == 0x5F // "_"
    }

    /// A reason a string could not be decoded as base64url.
    public enum DecodeError: Error, Sendable, Hashable {
        /// A character outside the base64url alphabet (for example `+`, `/`, or `=`).
        case invalidCharacter
        /// The length is impossible for base64 (a remainder of 1 after grouping).
        case invalidLength
        /// The input is well-formed base64url but not decodable.
        case invalidEncoding
    }
}

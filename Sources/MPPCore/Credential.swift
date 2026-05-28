import Foundation

/// A payment credential: the proof a client sends in `Authorization: Payment` to
/// satisfy a challenge.
///
/// Per `draft-httpauth-payment-00` §5.1, the header is
/// `Payment 1*SP base64url-nopad`, where the base64url payload is a JSON object
/// with the echoed `challenge`, an optional payer `source`, and a method-specific
/// `payload`. The challenge is echoed so the server can re-verify the
/// challenge-id binding; the `payload` is opaque to this layer and decoded by the
/// payment method.
public struct Credential: Sendable, Hashable, Codable {
    /// The challenge being answered, echoed from the server's `WWW-Authenticate`.
    public let challenge: Challenge
    /// Payer identifier (a DID is recommended); `nil` when the method omits it.
    public let source: String?
    /// Method-specific payment proof, carried opaquely by this layer.
    public let payload: [String: JSONValue]

    /// Creates a credential.
    public init(
        challenge: Challenge,
        source: String? = nil,
        payload: [String: JSONValue]
    ) {
        self.challenge = challenge
        self.source = source
        self.payload = payload
    }

    /// Decodes a credential from an `Authorization: Payment` header value.
    ///
    /// - Parameter headerValue: The full header value, `Payment <base64url>`.
    /// - Throws: ``ParsingError``.
    public init(headerValue: String) throws(ParsingError) {
        let token = try Self.token(from: headerValue)
        let data: Data
        do {
            data = try Base64URL.decode(token)
        } catch {
            throw .notBase64URL(error)
        }
        do {
            self = try JSONDecoder().decode(Credential.self, from: data)
        } catch {
            throw .invalidJSON(reason: String(describing: error))
        }
    }

    /// The `Authorization: Payment` header value for this credential.
    ///
    /// JSON keys are emitted in sorted order for a stable encoding.
    public var headerValue: String {
        get throws(ParsingError) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data: Data
            do {
                data = try encoder.encode(self)
            } catch {
                throw .invalidJSON(reason: String(describing: error))
            }
            return "\(PaymentAuthScheme.name) \(Base64URL.encode(data))"
        }
    }

    /// Extracts the base64url token after the case-insensitive `Payment` scheme.
    private static func token(from headerValue: String) throws(ParsingError) -> String {
        let parts = headerValue
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == PaymentAuthScheme.name.lowercased() else {
            throw .missingScheme
        }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { throw .missingScheme }
        return token
    }

    /// A reason an `Authorization: Payment` value is not a valid credential.
    public enum ParsingError: Error, Sendable, Hashable {
        /// The value did not start with the `Payment` scheme and a token.
        case missingScheme
        /// The credential token was not unpadded base64url.
        case notBase64URL(Base64URL.DecodeError)
        /// The decoded bytes were not a valid credential JSON object. `reason`
        /// carries the underlying coding error's description for diagnostics.
        case invalidJSON(reason: String)
    }
}

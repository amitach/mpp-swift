import Foundation

/// A payment receipt: proof of a settled payment, carried in the
/// `Payment-Receipt` response header.
///
/// Per `draft-httpauth-payment-00` §5.1, the header value is a base64url-encoded
/// JSON object with `status`, `method`, `timestamp`, and `reference`. A receipt
/// is issued only on success, so ``Status`` currently has the single
/// `success` value; an unrecognized status fails to decode.
public struct Receipt: Sendable, Hashable, Codable {
    /// The settlement status. Receipts are issued only on success.
    public let status: Status
    /// The payment method that settled the payment.
    public let method: MethodName
    /// When the payment settled.
    public let timestamp: RFC3339DateTime
    /// Method-specific settlement reference (transaction hash, invoice id, ...).
    public let reference: String

    /// Creates a receipt.
    public init(
        status: Status = .success,
        method: MethodName,
        timestamp: RFC3339DateTime,
        reference: String
    ) {
        self.status = status
        self.method = method
        self.timestamp = timestamp
        self.reference = reference
    }

    /// Decodes a receipt from a `Payment-Receipt` header value.
    ///
    /// - Parameter headerValue: The base64url-encoded JSON object.
    /// - Throws: ``Base64URL/DecodeError`` if the value is not base64url, or a
    ///   `DecodingError` if the JSON is not a valid receipt.
    public init(headerValue: String) throws {
        let data = try Base64URL.decode(headerValue)
        self = try JSONDecoder().decode(Receipt.self, from: data)
    }

    /// The `Payment-Receipt` header value: base64url(JSON) of this receipt.
    ///
    /// JSON keys are emitted in sorted order for a stable encoding.
    public var headerValue: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try Base64URL.encode(encoder.encode(self))
        }
    }

    /// The settlement status of a payment.
    public enum Status: String, Sendable, Hashable, Codable {
        /// The payment settled successfully.
        case success
    }
}

import Foundation

/// A payment receipt: proof of a settled payment, carried in the
/// `Payment-Receipt` response header.
///
/// Per `draft-httpauth-payment-00` §5.1, the header value is a base64url-encoded
/// JSON object with `status`, `method`, `timestamp`, and `reference`. A receipt
/// is issued only on success, so ``Status`` currently has the single
/// `success` value; an unrecognized status fails to decode.
///
/// Decoding is deliberately lenient about unknown JSON fields: a server may add
/// method-specific or future fields to a receipt, and rejecting them would break
/// interoperability with a newer peer. The four fields above are required.
///
/// A payment method may add its own top-level fields via ``extras`` (a Tempo
/// session receipt adds `intent`, `channelId`, `acceptedCumulative`, `spent`,
/// `units`, ...). They are emitted alongside the base fields and, on decode, any
/// string- or integer-valued key that is not one of the four base fields is captured
/// back into ``extras`` (other JSON types are still ignored, preserving the lenient
/// decode). The string/integer distinction is preserved on the wire: the reference
/// session receipt types every field as a string except `units` (a JSON integer), so
/// a faithful round-trip must keep `units` numeric. A receipt with no extras is
/// byte-identical to before.
public struct Receipt: Sendable, Hashable {
    /// The settlement status. Receipts are issued only on success.
    public let status: Status
    /// The payment method that settled the payment.
    public let method: MethodName
    /// When the payment settled.
    public let timestamp: RFC3339DateTime
    /// Method-specific settlement reference (transaction hash, invoice id, ...).
    /// Its format and whether it may be empty are defined by the payment method.
    public let reference: String
    /// Method-specific extra top-level fields, emitted alongside the base fields.
    /// Each value is a JSON string or integer (see ``ReceiptValue``). Empty for a
    /// plain receipt.
    public let extras: [String: ReceiptValue]

    /// A method-specific extra receipt field's value: a JSON string or integer. The
    /// reference session receipt types every field as a string except `units` (a
    /// `u64`), so the two cases must stay distinct on the wire.
    public enum ReceiptValue: Sendable, Hashable {
        case string(String)
        case int(Int64)
    }

    /// Creates a receipt.
    public init(
        status: Status = .success,
        method: MethodName,
        timestamp: RFC3339DateTime,
        reference: String,
        extras: [String: ReceiptValue] = [:]
    ) {
        self.status = status
        self.method = method
        self.timestamp = timestamp
        self.reference = reference
        // A base field can never be shadowed by an extra.
        self.extras = extras.filter { !Self.baseKeys.contains($0.key) }
    }

    fileprivate static let baseKeys: Set<String> = ["status", "method", "timestamp", "reference"]

    /// A string coding key, for the base fields plus dynamic ``extras``.
    fileprivate struct Key: CodingKey {
        let stringValue: String
        init(_ string: String) {
            stringValue = string
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        var intValue: Int? {
            nil
        }

        init?(intValue _: Int) {
            nil
        }
    }

    /// Decodes a receipt from a `Payment-Receipt` header value.
    ///
    /// - Parameter headerValue: The base64url-encoded JSON object.
    /// - Throws: ``ParsingError``.
    public init(headerValue: String) throws(ParsingError) {
        let data: Data
        do {
            data = try Base64URL.decode(headerValue)
        } catch {
            throw .notBase64URL(error)
        }
        do {
            self = try JSONDecoder().decode(Receipt.self, from: data)
        } catch {
            throw .invalidJSON(reason: String(describing: error))
        }
    }

    /// The `Payment-Receipt` header value: base64url(JSON) of this receipt.
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
            return Base64URL.encode(data)
        }
    }

    /// The settlement status of a payment.
    public enum Status: String, Sendable, Hashable, Codable {
        /// The payment settled successfully.
        case success
    }

    /// A reason a `Payment-Receipt` value is not a valid receipt.
    public enum ParsingError: Error, Sendable, Hashable {
        /// The header value was not unpadded base64url.
        case notBase64URL(Base64URL.DecodeError)
        /// The decoded bytes were not a valid receipt JSON object. `reason`
        /// carries the underlying coding error's description for diagnostics.
        case invalidJSON(reason: String)
    }
}

extension Receipt: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        status = try container.decode(Status.self, forKey: Key("status"))
        method = try container.decode(MethodName.self, forKey: Key("method"))
        timestamp = try container.decode(RFC3339DateTime.self, forKey: Key("timestamp"))
        reference = try container.decode(String.self, forKey: Key("reference"))
        var captured: [String: ReceiptValue] = [:]
        for key in container.allKeys where !Self.baseKeys.contains(key.stringValue) {
            // Lenient + type-preserving: capture string- and integer-valued unknowns
            // (a JSON string stays a string, a JSON integer stays an int), ignore the
            // rest (floats, bools, objects). Decode String first so a quoted "5" is a
            // string, not an int.
            if let value = try? container.decode(String.self, forKey: key) {
                captured[key.stringValue] = .string(value)
            } else if let value = try? container.decode(Int64.self, forKey: key) {
                captured[key.stringValue] = .int(value)
            }
        }
        extras = captured
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(status, forKey: Key("status"))
        try container.encode(method, forKey: Key("method"))
        try container.encode(timestamp, forKey: Key("timestamp"))
        try container.encode(reference, forKey: Key("reference"))
        for (key, value) in extras {
            switch value {
            case let .string(string): try container.encode(string, forKey: Key(key))
            case let .int(int): try container.encode(int, forKey: Key(key))
            }
        }
    }
}

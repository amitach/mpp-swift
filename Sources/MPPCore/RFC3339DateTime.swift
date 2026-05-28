import Foundation

/// An RFC 3339 `date-time`, preserved verbatim alongside its parsed instant.
///
/// Several MPP fields are RFC 3339 timestamps: the challenge `expires`
/// (`draft-httpauth-payment-00` §5.1) and the receipt `timestamp`. This is the
/// single primitive that parses and formats them. The original string is kept
/// in ``rawValue`` because some timestamps are bound by the challenge-id HMAC,
/// so reformatting (for example dropping fractional seconds) would change the
/// bytes. Equality is therefore by the verbatim ``rawValue``: two different
/// encodings of the same instant are distinct values (their wire bytes differ).
/// Compare ``date`` directly when you need instant equality rather than byte
/// equality.
public struct RFC3339DateTime: Sendable, Hashable {
    /// The timestamp exactly as received, preserved for binding integrity.
    public let rawValue: String

    /// The parsed instant.
    public let date: Date

    /// Parses an RFC 3339 timestamp, preserving the original string.
    ///
    /// - Parameter rawValue: An RFC 3339 `date-time`, with or without
    ///   fractional seconds, using `Z` or a numeric UTC offset.
    /// - Throws: ``ParsingError/malformed`` if the value is not RFC 3339.
    public init(_ rawValue: String) throws(ParsingError) {
        guard let date = Self.parse(rawValue) else { throw .malformed }
        self.rawValue = rawValue
        self.date = date
    }

    /// Creates a timestamp from an instant, formatting it as RFC 3339 (`Z`, no
    /// fractional seconds).
    ///
    /// `date` is taken from the formatted string, not the input, so it always
    /// matches ``rawValue`` (mint precision is whole seconds): any sub-second
    /// component of `date` is dropped, keeping `rawValue` the single source of
    /// truth and the encode/decode round-trip stable.
    public init(date: Date) {
        let formatted = Self.format(date)
        rawValue = formatted
        self.date = Self.parse(formatted) ?? date
    }

    /// The value was not a valid RFC 3339 timestamp.
    public enum ParsingError: Error, Sendable, Hashable {
        /// The string did not parse as an RFC 3339 `date-time`.
        case malformed
    }
}

extension RFC3339DateTime {
    // RFC 3339 allows optional fractional seconds, which a single
    // ISO8601DateFormatter cannot match both with and without. Try the
    // fractional form first, then the plain form. Formatters are created per
    // call (they are reference types and not safely shared under strict
    // concurrency); timestamp parsing is not a hot path.
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// Transparent Codable + description come from RawStringValidated.
extension RFC3339DateTime: RawStringValidated {}

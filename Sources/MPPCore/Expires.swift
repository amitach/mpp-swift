import Foundation

/// A challenge expiry: an RFC 3339 timestamp after which a payment challenge is
/// no longer valid.
///
/// Per `draft-httpauth-payment-00` §5.1, the `expires` parameter is an RFC 3339
/// `date-time`. The original string is preserved verbatim in ``rawValue``
/// because the challenge-id HMAC binds the literal `expires` value; reformatting
/// it (for example dropping fractional seconds) would break that binding.
///
/// Expiry checks take an explicit `now` rather than reading `Date.now`
/// internally, so callers (and tests) are deterministic.
public struct Expires: Sendable, Hashable {
    /// The underlying RFC 3339 timestamp.
    private let instant: RFC3339DateTime

    /// The RFC 3339 timestamp exactly as received, preserved for binding integrity.
    public var rawValue: String {
        instant.rawValue
    }

    /// The parsed instant the challenge expires.
    public var date: Date {
        instant.date
    }

    /// Parses an RFC 3339 timestamp, preserving the original string.
    ///
    /// - Parameter rawValue: An RFC 3339 `date-time`, with or without
    ///   fractional seconds, using `Z` or a numeric UTC offset.
    /// - Throws: ``ParsingError/malformed`` if the value is not RFC 3339.
    public init(_ rawValue: String) throws(ParsingError) {
        do {
            instant = try RFC3339DateTime(rawValue)
        } catch {
            throw .malformed
        }
    }

    /// Creates an expiry from an instant, formatting it as RFC 3339 (`Z`, no
    /// fractional seconds). Use when minting a fresh challenge.
    public init(date: Date) {
        instant = RFC3339DateTime(date: date)
    }

    /// Whether the challenge has expired as of `now`.
    ///
    /// The expiry instant itself is still valid: the window is `now <= expires`,
    /// so `now == expires` returns `false` and a challenge is expired only once
    /// `now` is strictly past `expires`. `draft-httpauth-payment-00` §5.1 is
    /// silent on the exact instant; this is a deliberate interop choice (the
    /// boundary semantics are verified identical across both reference SDKs).
    public func isExpired(at now: Date) -> Bool {
        date < now
    }

    /// Throws if the challenge has expired as of `now`.
    public func validate(at now: Date) throws(ExpiredError) {
        if isExpired(at: now) {
            throw ExpiredError(expires: rawValue)
        }
    }

    /// The value was not a valid RFC 3339 timestamp.
    public enum ParsingError: Error, Sendable, Hashable {
        /// The string did not parse as an RFC 3339 `date-time`.
        case malformed
    }

    /// The challenge had already expired.
    public struct ExpiredError: Error, Sendable, Hashable {
        /// The expiry that was exceeded.
        public let expires: String
    }
}

// Transparent Codable + description come from RawStringValidated.
extension Expires: RawStringValidated {}

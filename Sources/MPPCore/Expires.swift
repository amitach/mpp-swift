import Foundation

/// A challenge expiry: an RFC 3339 timestamp after which a payment challenge is
/// no longer valid.
///
/// Per `draft-httpauth-payment-00` §5.1, the `expires` parameter is an RFC 3339
/// `date-time`. The original string is preserved verbatim in ``rawValue``
/// because the challenge-id HMAC binds the literal `expires` value; reformatting
/// it (for example dropping fractional seconds) would break that binding.
///
/// Expiry checks take an explicit `now` rather than reading the system clock, so
/// callers (and tests) are deterministic, rather than reading `Date.now`
/// internally.
public struct Expires: Sendable, Hashable {
    /// The RFC 3339 timestamp exactly as received, preserved for binding integrity.
    public let rawValue: String

    /// The parsed instant the challenge expires.
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

    /// Creates an expiry from an instant, formatting it as RFC 3339 (`Z`, no
    /// fractional seconds). Use when minting a fresh challenge.
    public init(date: Date) {
        self.date = date
        rawValue = Self.format(date)
    }

    /// Whether the challenge has expired as of `now`.
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
        case malformed
    }

    /// The challenge had already expired.
    public struct ExpiredError: Error, Sendable, Hashable {
        /// The expiry that was exceeded.
        public let expires: String
    }
}

public extension Expires {
    /// An expiry `count` seconds after `now`.
    static func seconds(_ count: Int, from now: Date) -> Expires {
        Expires(date: now.addingTimeInterval(TimeInterval(count)))
    }

    /// An expiry `count` minutes after `now`.
    static func minutes(_ count: Int, from now: Date) -> Expires {
        seconds(count * 60, from: now)
    }

    /// An expiry `count` hours after `now`.
    static func hours(_ count: Int, from now: Date) -> Expires {
        minutes(count * 60, from: now)
    }

    /// An expiry `count` days after `now`.
    static func days(_ count: Int, from now: Date) -> Expires {
        hours(count * 24, from: now)
    }
}

extension Expires {
    // RFC 3339 allows optional fractional seconds, which a single
    // ISO8601DateFormatter cannot match both with and without. Try the
    // fractional form first, then the plain form. Formatters are created per
    // call (they are reference types and not safely shared under strict
    // concurrency); expiry parsing is not a hot path.
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
extension Expires: RawStringValidated {}

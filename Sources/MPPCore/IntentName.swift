/// A payment intent identifier, such as `charge`, `session`, or `subscription`.
///
/// Per `draft-httpauth-payment-00` Appendix A, an intent identifier is
/// `intent-token = 1*( ALPHA / DIGIT / "-" )`: one or more ASCII letters
/// (either case), digits, or hyphens. Section 5.1.1 also requires the value to
/// be registered in the IANA "HTTP Payment Intents" registry; registration is
/// out of scope for this type, which validates only the wire grammar.
///
/// Unlike ``MethodName``, the spec does **not** require intent values to be
/// lowercase, so case is preserved exactly. This is intentionally different
/// from `mpp-rs`, which lowercases the intent on creation (`types.rs:107`) and
/// would corrupt a spec-legal mixed-case token; comparison is case-sensitive,
/// matching the registered (lowercase) intent names.
public struct IntentName: Sendable, Hashable {
    /// The validated identifier, guaranteed to match `1*( ALPHA / DIGIT / "-" )`.
    public let rawValue: String

    /// Creates an intent name, validating the `1*( ALPHA / DIGIT / "-" )` grammar.
    ///
    /// - Parameter rawValue: The candidate identifier.
    /// - Throws: ``ValidationError/empty`` if `rawValue` has no characters, or
    ///   ``ValidationError/invalidCharacter(_:)`` for the first character
    ///   outside `A`–`Z`, `a`–`z`, `0`–`9`, or `-`.
    public init(_ rawValue: String) throws(ValidationError) {
        guard !rawValue.isEmpty else { throw .empty }
        for scalar in rawValue.unicodeScalars where !Self.isAllowed(scalar) {
            throw .invalidCharacter(Character(scalar))
        }
        self.rawValue = rawValue
    }

    /// Creates an intent name without validation.
    ///
    /// For compile-time-known-valid identifiers defined within the package (the
    /// registered intent constants below). The caller is responsible for
    /// conformance to the grammar.
    package init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x41 ... 0x5A).contains(value) // A-Z
            || (0x61 ... 0x7A).contains(value) // a-z
            || (0x30 ... 0x39).contains(value) // 0-9
            || value == 0x2D // "-"
    }

    /// A reason a candidate value is not a valid ``IntentName``.
    public enum ValidationError: Error, Sendable, Hashable {
        /// The value had no characters; at least one is required.
        case empty
        /// The value contained a character outside `A`–`Z`, `a`–`z`, `0`–`9`, `-`.
        case invalidCharacter(Character)
    }
}

public extension IntentName {
    /// The `charge` intent: a one-time payment in exchange for a single resource.
    static let charge = IntentName(unchecked: "charge")
    /// The `session` intent: pay-as-you-go over a payment channel.
    static let session = IntentName(unchecked: "session")
    /// The `subscription` intent: recurring payment across billing periods.
    static let subscription = IntentName(unchecked: "subscription")
}

extension IntentName: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

extension IntentName: Codable {
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        do {
            self = try IntentName(rawValue)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid intent name \"\(rawValue)\": \(error)"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

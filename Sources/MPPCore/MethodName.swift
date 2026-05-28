/// A payment method identifier, such as `tempo` or `stripe`.
///
/// Per `draft-httpauth-payment-00` Appendix A, a method identifier is
/// `payment-method-id = 1*LOWERALPHA` where `LOWERALPHA = %x61-7A`: one or more
/// lowercase ASCII letters (`a`–`z`), and nothing else. Section 5.1.1 also
/// requires the value to be registered in the IANA "HTTP Payment Methods"
/// registry; registration is out of scope for this type, which validates only
/// the wire grammar.
///
/// Construction is validating and strict: non-conforming input (uppercase,
/// digits, hyphens, or empty) is rejected rather than normalized. This is
/// intentionally stricter than the reference SDKs — `mppx` performs no
/// validation and `mpp-rs` silently lowercases — matching the spec's
/// requirement that non-conforming input be rejected.
public struct MethodName: Sendable, Hashable {
    /// The validated identifier, guaranteed to match `1*LOWERALPHA`.
    public let rawValue: String

    /// Creates a method name, validating the `1*LOWERALPHA` grammar.
    ///
    /// - Parameter rawValue: The candidate identifier.
    /// - Throws: ``ValidationError/empty`` if `rawValue` has no characters, or
    ///   ``ValidationError/invalidCharacter(_:)`` for the first character
    ///   outside `a`–`z`.
    public init(_ rawValue: String) throws(ValidationError) {
        guard !rawValue.isEmpty else { throw .empty }
        for scalar in rawValue.unicodeScalars where !(0x61...0x7A).contains(scalar.value) {
            throw .invalidCharacter(Character(scalar))
        }
        self.rawValue = rawValue
    }

    /// Creates a method name without validation.
    ///
    /// For compile-time-known-valid identifiers defined within the package
    /// (for example a rail module declaring its own method constant). The
    /// caller is responsible for conformance to `1*LOWERALPHA`.
    package init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// A reason a candidate value is not a valid ``MethodName``.
    public enum ValidationError: Error, Sendable, Hashable {
        /// The value had no characters; at least one is required.
        case empty
        /// The value contained a character outside `a`–`z`.
        case invalidCharacter(Character)
    }
}

extension MethodName: CustomStringConvertible {
    public var description: String { rawValue }
}

extension MethodName: Codable {
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        do {
            self = try MethodName(rawValue)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid method name \"\(rawValue)\": \(error)"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

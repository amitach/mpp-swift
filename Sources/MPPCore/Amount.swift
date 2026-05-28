/// A non-negative payment amount in base units (the smallest denomination of
/// the currency or token), carried on the wire as a canonical decimal integer
/// string.
///
/// Per `draft-payment-intent-charge-00` and `draft-payment-discovery-00`, the
/// `amount` is an integer in base units. The canonical string form is a
/// non-negative integer with no leading zeros, matching the discovery grammar
/// `0 / [1-9][0-9]*`; `"0"` is allowed (zero-amount charges are valid).
///
/// This is the strict on-wire form. Human-readable decimal input (for example
/// `"1.5"` with a decimals scale) is converted to base units by a separate
/// helper at the charge layer; a decimal string is not itself a valid
/// `Amount`. There is no floating-point representation anywhere; amounts are
/// exact integers. Validation is intentionally strict: it enforces the
/// normative canonical discovery grammar (non-negative integer base units, no
/// leading zeros) for the value that travels on the wire, rather than accepting
/// lenient human-readable input.
public struct Amount: Sendable, Hashable {
    /// The canonical non-negative integer in base units, with no leading zeros.
    public let rawValue: String

    /// Creates an amount from a canonical base-units string.
    ///
    /// - Parameter rawValue: A non-negative integer with no leading zeros
    ///   (`"0"`, `"1"`, `"1000000"`).
    /// - Throws: ``ValidationError`` if empty, non-numeric, or has a leading zero.
    public init(_ rawValue: String) throws(ValidationError) {
        try Self.validate(rawValue)
        self.rawValue = rawValue
    }

    private static func validate(_ value: String) throws(ValidationError) {
        guard !value.isEmpty else { throw .empty }
        for scalar in value.unicodeScalars where !(0x30 ... 0x39).contains(scalar.value) {
            throw .invalidCharacter(Character(scalar))
        }
        if value.count > 1, value.first == "0" {
            throw .leadingZero
        }
    }

    /// A reason a candidate value is not a valid ``Amount``.
    public enum ValidationError: Error, Sendable, Hashable {
        /// The value had no characters; at least one digit is required.
        case empty
        /// The value contained a non-digit character (including `.` or `-`).
        case invalidCharacter(Character)
        /// The value had a leading zero (only `"0"` itself may start with `0`).
        case leadingZero
    }
}

// Transparent Codable + description come from RawStringValidated.
extension Amount: RawStringValidated {}

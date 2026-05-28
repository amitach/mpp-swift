/// A value backed by a validated canonical string.
///
/// Several MPP primitives (``MethodName``, ``IntentName``, ``Amount``,
/// ``Expires``) are "a string that must satisfy a grammar." They differ only
/// in the grammar (and its error); the *serialization mechanism* is identical:
/// transparent (single-value) `Codable` that re-validates on decode, and a
/// `description` equal to the raw value. This protocol supplies that mechanism
/// once so it lives in a single place. Conformers provide only ``rawValue`` and
/// a validating initializer; the validation rule and error type stay per type.
public protocol RawStringValidated: Codable, CustomStringConvertible, Sendable, Hashable {
    /// The validated canonical string form.
    var rawValue: String { get }

    /// Creates a value by validating `rawValue`, throwing if it is invalid.
    init(_ rawValue: String) throws
}

public extension RawStringValidated {
    var description: String {
        rawValue
    }

    init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        do {
            self = try Self(rawValue)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid \(Self.self) \"\(rawValue)\": \(error)"
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

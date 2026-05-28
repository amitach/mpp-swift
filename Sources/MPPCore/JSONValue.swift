/// A JSON value restricted to the types the Machine Payments Protocol uses in
/// challenge `request` objects: objects, arrays, strings, integers, booleans,
/// and null.
///
/// MPP deliberately carries monetary amounts as *strings* (see ``Amount``), so
/// request JSON never contains floating-point numbers; modelling numbers as
/// integers here makes that guarantee structural — a non-integer number cannot
/// be represented, so ``canonicalized()`` cannot silently mis-serialize one.
///
/// ``canonicalized()`` produces the RFC 8785 (JSON Canonicalization Scheme)
/// form used for the base64url-encoded `request` parameter. Both reference SDKs
/// delegate JCS to a library (mppx to `ox`, mpp-rs to `serde_json_canonicalizer`),
/// so RFC 8785 is the authoritative reference; this implements the subset the
/// protocol uses, byte-for-byte: object keys sorted by UTF-16 code units, RFC
/// 8785 string escaping, integers as plain decimals, and no insignificant
/// whitespace.
public indirect enum JSONValue: Sendable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null

    /// The RFC 8785 canonical JSON serialization of this value.
    public func canonicalized() -> String {
        switch self {
        case let .object(members):
            let body = members
                .sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
                .map { "\(Self.escapeString($0.key)):\($0.value.canonicalized())" }
                .joined(separator: ",")
            return "{\(body)}"
        case let .array(elements):
            return "[\(elements.map { $0.canonicalized() }.joined(separator: ","))]"
        case let .string(value):
            return Self.escapeString(value)
        case let .integer(value):
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    /// Escapes a string per RFC 8785 §3.2.2.2: minimal JSON escaping with
    /// lowercase `\u00xx` for the remaining control characters, and every other
    /// character (including non-ASCII) emitted literally.
    static func escapeString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{09}": result += "\\t"
            case "\u{0A}": result += "\\n"
            case "\u{0C}": result += "\\f"
            case "\u{0D}": result += "\\r"
            case let other where other.value < 0x20:
                // Control chars 0x00–0x1F: lowercase \u00xx, zero-padded to 2 digits.
                let hex = String(other.value, radix: 16)
                result += "\\u00" + (hex.count == 1 ? "0\(hex)" : hex)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral _: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

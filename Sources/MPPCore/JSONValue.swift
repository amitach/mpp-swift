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
/// form used for the base64url-encoded `request` parameter. RFC 8785 is the
/// authoritative reference; this implements the subset the
/// protocol uses, byte-for-byte: object keys sorted by UTF-16 code units, RFC
/// 8785 string escaping, integers as plain decimals, and no insignificant
/// whitespace.
public indirect enum JSONValue: Sendable, Hashable {
    /// A JSON object; keys are sorted by UTF-16 code units when canonicalized.
    case object([String: JSONValue])
    /// A JSON array; element order is preserved.
    case array([JSONValue])
    /// A JSON string.
    case string(String)
    /// A JSON integer (MPP request numbers are integers; floats are excluded).
    case integer(Int64)
    /// A JSON boolean.
    case bool(Bool)
    /// JSON `null`.
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
    private static func escapeString(_ value: String) -> String {
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

// Intentionally no ExpressibleByNilLiteral: it would make `nil` ambiguous with
// Optional<JSONValue>. Use `.null` explicitly.

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        // Last value wins on a duplicate key rather than trapping; a JSON object
        // should not have duplicate keys, but a crash here would be worse.
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// `Codable` lets `JSONValue` carry an opaque, method-specific credential payload
// (an arbitrary JSON object). Decoding stays integer-only: a floating-point
// number is rejected rather than silently truncated, keeping the no-float
// guarantee that the rest of the protocol relies on.
extension JSONValue: Codable {
    private struct ObjectKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: ObjectKey.self) {
            var object: [String: JSONValue] = [:]
            // A well-formed JSON object has unique keys; on a duplicate the
            // decoder keeps the first occurrence (the dictionary literal above is
            // last-wins, but neither case should arise in conforming input).
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !unkeyed.isAtEnd {
                try array.append(unkeyed.decode(JSONValue.self))
            }
            self = .array(array)
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let bool = try? single.decode(Bool.self) {
                self = .bool(bool)
            } else if let integer = try? single.decode(Int64.self) {
                self = .integer(integer)
            } else if let string = try? single.decode(String.self) {
                self = .string(string)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unsupported JSON value: MPP JSON is object, array, "
                        + "string, integer, bool, or null; floating-point numbers are not allowed."
                )
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .object(members):
            var container = encoder.container(keyedBy: ObjectKey.self)
            for (key, value) in members {
                try container.encode(value, forKey: ObjectKey(stringValue: key))
            }
        case let .array(elements):
            var container = encoder.unkeyedContainer()
            for element in elements {
                try container.encode(element)
            }
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .integer(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

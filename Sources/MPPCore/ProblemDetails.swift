/// An RFC 9457 problem details object (`application/problem+json`), the error
/// body a server returns with a `402 Payment Required` (and other failures).
///
/// Per `draft-httpauth-payment-00` §8, servers SHOULD return a problem body on a
/// 402. All five standard members (RFC 9457 §3.1) are optional; an absent `type`
/// is interpreted as `about:blank`. Anything beyond the standard members is an
/// extension member (for example MPP's `challengeId`), preserved in
/// ``extensions`` so a consumer can read protocol-specific fields without this
/// type having to know them.
public struct ProblemDetails: Sendable, Hashable {
    /// A URI reference identifying the problem type. Absent ⇒ `about:blank`.
    public var type: String?
    /// A short, human-readable summary of the problem type.
    public var title: String?
    /// The HTTP status code generated for this occurrence.
    public var status: Int?
    /// A human-readable explanation specific to this occurrence.
    public var detail: String?
    /// A URI reference identifying the specific occurrence.
    public var instance: String?
    /// Extension members beyond the five standard ones (e.g. `challengeId`),
    /// carried opaquely. Never contains a standard-member key.
    public var extensions: [String: JSONValue]

    /// Creates a problem details object.
    public init(
        type: String? = nil,
        title: String? = nil,
        status: Int? = nil,
        detail: String? = nil,
        instance: String? = nil,
        extensions: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.title = title
        self.status = status
        self.detail = detail
        self.instance = instance
        self.extensions = extensions
    }
}

extension ProblemDetails: Codable {
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }

        static let type = Key(stringValue: "type")
        static let title = Key(stringValue: "title")
        static let status = Key(stringValue: "status")
        static let detail = Key(stringValue: "detail")
        static let instance = Key(stringValue: "instance")
    }

    /// The standard member names; everything else is an extension member.
    private static let standardKeys: Set<String> = ["type", "title", "status", "detail", "instance"]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        instance = try container.decodeIfPresent(String.self, forKey: .instance)

        var extensions: [String: JSONValue] = [:]
        for key in container.allKeys where !Self.standardKeys.contains(key.stringValue) {
            extensions[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extensions = extensions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(instance, forKey: .instance)

        // A standard member is authoritative from its typed field; never let an
        // extension key shadow one (a well-formed problem object has none).
        for (key, value) in extensions where !Self.standardKeys.contains(key) {
            try container.encode(value, forKey: Key(stringValue: key))
        }
    }
}

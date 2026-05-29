import Foundation

/// Documentation links for a service, from `x-service-info.docs`. Each present
/// link must be an absolute URI (`scheme://...`) or an absolute path (`/...`)
/// with no whitespace, matching the discovery grammar.
public struct ServiceDocs: Sendable, Hashable, Codable {
    /// A URI or path to the API reference.
    public var apiReference: String?
    /// A URI or path to the service homepage.
    public var homepage: String?
    /// A URI or path to an `llms.txt`-style machine-readable description.
    public var llms: String?

    public init(apiReference: String? = nil, homepage: String? = nil, llms: String? = nil) {
        self.apiReference = apiReference
        self.homepage = homepage
        self.llms = llms
    }

    /// A reason a documentation link is invalid.
    public enum DecodingFailure: Error, Sendable, Hashable {
        /// A link was neither a `scheme://` URI nor a `/` path (or contained whitespace).
        case invalidLink(field: String, value: String)
    }

    // The wire keys are the canonical `x-service-info.docs` field names from the
    // discovery spec: `apiReference` (camelCase), `homepage`, `llms`. The camelCase
    // `apiReference` is intentional and matches the spec; do not snake-case it.
    private enum CodingKeys: String, CodingKey {
        case apiReference, homepage, llms
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiReference = try Self.link(container, .apiReference, field: "apiReference")
        homepage = try Self.link(container, .homepage, field: "homepage")
        llms = try Self.link(container, .llms, field: "llms")
    }

    private static func link(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        field: String
    ) throws -> String? {
        guard let value = try container.decodeIfPresent(String.self, forKey: key)
        else { return nil }
        guard isURIOrPath(value) else {
            throw DecodingFailure.invalidLink(field: field, value: value)
        }
        return value
    }

    /// Matches the discovery grammar `scheme://non-space+` or `/non-space*`.
    static func isURIOrPath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        if value.hasPrefix("/") { return true }
        guard let schemeEnd = value.range(of: "://") else { return false }
        let scheme = value[value.startIndex ..< schemeEnd.lowerBound]
        let rest = value[schemeEnd.upperBound...]
        guard !rest.isEmpty, let first = scheme.first, first.isASCII, first.isLetter else {
            return false
        }
        return scheme.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-")
        }
    }
}

/// The `x-service-info` OpenAPI extension at the document root: service-level
/// metadata that complements the per-operation `x-payment-info`.
public struct ServiceInfo: Sendable, Hashable, Codable {
    /// Free-form service categories.
    public var categories: [String]?
    /// Documentation links.
    public var docs: ServiceDocs?

    public init(categories: [String]? = nil, docs: ServiceDocs? = nil) {
        self.categories = categories
        self.docs = docs
    }
}

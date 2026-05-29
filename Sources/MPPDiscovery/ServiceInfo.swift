import Foundation

/// Documentation links for a service, from `x-service-info.docs`.
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

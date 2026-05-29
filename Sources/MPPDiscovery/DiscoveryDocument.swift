import Foundation

/// An MPP discovery document: an OpenAPI document carrying the `x-service-info`
/// root extension and per-operation `x-payment-info` extensions.
///
/// Parsing accepts OpenAPI `3.0.x` and `3.1.x` inputs and reads only the
/// discovery-relevant fields (version, `info`, `paths` operations, the
/// extensions), tolerating and ignoring the rest of the document, so a real
/// OpenAPI file with arbitrary content still parses. Encoding always emits
/// `3.1.0`. (Round-tripping the full foreign document verbatim is out of scope;
/// the model captures the discovery surface, which is what a client needs.)
public struct DiscoveryDocument: Sendable, Hashable {
    /// The `openapi` version string of the parsed input (emit is always 3.1.0).
    public var openapi: String
    /// The `info` object (title, version).
    public var info: Info
    /// `paths`: path string to (HTTP method to operation).
    public var paths: [String: [HTTPMethod: DiscoveryOperation]]
    /// The `x-service-info` root extension, if present.
    public var serviceInfo: ServiceInfo?

    public init(
        openapi: String = "3.1.0",
        info: Info,
        paths: [String: [HTTPMethod: DiscoveryOperation]] = [:],
        serviceInfo: ServiceInfo? = nil
    ) {
        self.openapi = openapi
        self.info = info
        self.paths = paths
        self.serviceInfo = serviceInfo
    }

    /// The OpenAPI `info` object (the discovery-relevant subset).
    public struct Info: Sendable, Hashable, Codable {
        public var title: String
        public var version: String
        public init(title: String, version: String) {
            self.title = title
            self.version = version
        }
    }

    /// A reason a discovery document is unparseable at the version level.
    public enum DecodingFailure: Error, Sendable, Hashable {
        /// The `openapi` version major was neither 3.0.x nor 3.1.x.
        case unsupportedOpenAPIVersion(String)
    }
}

/// An HTTP method that can carry an OpenAPI operation.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable, Codable {
    case get, put, post, delete, options, head, patch, trace
}

/// An OpenAPI operation (the discovery-relevant subset).
public struct DiscoveryOperation: Sendable, Hashable, Codable {
    /// The `x-payment-info` extension, if present.
    public var paymentInfo: PaymentInfo?
    /// The operation summary, if present.
    public var summary: String?
    public init(paymentInfo: PaymentInfo? = nil, summary: String? = nil) {
        self.paymentInfo = paymentInfo
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case paymentInfo = "x-payment-info"
        case summary
    }
}

extension DiscoveryDocument: Codable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }

        init(_ value: String) {
            stringValue = value
        }
    }

    private enum FixedKey: String, CodingKey {
        case openapi, info, paths
        case serviceInfo = "x-service-info"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FixedKey.self)
        openapi = try container.decode(String.self, forKey: .openapi)
        guard openapi.hasPrefix("3.0.") || openapi.hasPrefix("3.1.")
            || openapi == "3.0" || openapi == "3.1"
        else {
            throw DecodingFailure.unsupportedOpenAPIVersion(openapi)
        }
        info = try container.decode(Info.self, forKey: .info)
        serviceInfo = try container.decodeIfPresent(ServiceInfo.self, forKey: .serviceInfo)

        var result: [String: [HTTPMethod: DiscoveryOperation]] = [:]
        if container.contains(.paths) {
            let pathsContainer = try container.nestedContainer(
                keyedBy: DynamicKey.self, forKey: .paths
            )
            for pathKey in pathsContainer.allKeys {
                let itemContainer = try pathsContainer.nestedContainer(
                    keyedBy: DynamicKey.self, forKey: pathKey
                )
                var operations: [HTTPMethod: DiscoveryOperation] = [:]
                // Decode only the keys that are HTTP methods; ignore the rest of the
                // path item (parameters, $ref, summary, and anything else), so
                // arbitrary OpenAPI content does not break parsing.
                for methodKey in itemContainer.allKeys {
                    guard let method = HTTPMethod(rawValue: methodKey.stringValue) else { continue }
                    operations[method] = try itemContainer.decode(
                        DiscoveryOperation.self, forKey: methodKey
                    )
                }
                if !operations.isEmpty {
                    result[pathKey.stringValue] = operations
                }
            }
        }
        paths = result
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FixedKey.self)
        // Emit is always OpenAPI 3.1.0 regardless of the parsed input version.
        try container.encode("3.1.0", forKey: .openapi)
        try container.encode(info, forKey: .info)
        try container.encodeIfPresent(serviceInfo, forKey: .serviceInfo)

        var pathsContainer = container.nestedContainer(keyedBy: DynamicKey.self, forKey: .paths)
        for (path, operations) in paths {
            var itemContainer = pathsContainer.nestedContainer(
                keyedBy: DynamicKey.self, forKey: DynamicKey(path)
            )
            for (method, operation) in operations {
                try itemContainer.encode(operation, forKey: DynamicKey(method.rawValue))
            }
        }
    }
}

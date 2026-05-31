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
    /// The conventional path a service publishes its discovery document at: `GET /openapi.json`,
    /// served over HTTPS with `Content-Type: application/json` (the Payment Discovery spec).
    public static let conventionalPath = "/openapi.json"
    /// The media type of the served document.
    public static let mediaType = "application/json"

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
public enum HTTPMethod: String, Sendable, Hashable, Codable {
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

    /// Accepts an `openapi` of major.minor `3.0` or `3.1`, with an optional
    /// all-numeric patch (and further numeric components). Rejects a non-numeric
    /// suffix such as `3.1.evil` and any other major.minor such as `3.10`.
    private static func isSupportedVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "3", parts[1] == "0" || parts[1] == "1" else {
            return false
        }
        for component in parts.dropFirst(2) {
            guard !component.isEmpty, component.allSatisfy({ ("0" ... "9").contains($0) }) else {
                return false
            }
        }
        return true
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FixedKey.self)
        openapi = try container.decode(String.self, forKey: .openapi)
        guard Self.isSupportedVersion(openapi) else {
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
                // A path-item value that is not an object (a `$ref` string, an array,
                // null) carries no operations to extract; skip it rather than fail,
                // so an arbitrary but valid OpenAPI document still parses.
                guard let itemContainer = try? pathsContainer.nestedContainer(
                    keyedBy: DynamicKey.self, forKey: pathKey
                ) else { continue }
                var operations: [HTTPMethod: DiscoveryOperation] = [:]
                // Decode only the keys that are HTTP methods; ignore the rest of the
                // path item (parameters, $ref, summary, and anything else).
                for methodKey in itemContainer.allKeys {
                    guard let method = HTTPMethod(rawValue: methodKey.stringValue) else { continue }
                    // Skip a method value that is not an object (for example a `$ref`
                    // string); but a malformed operation object still surfaces its
                    // error (so a bad `x-payment-info` is reported, not swallowed).
                    guard (try? itemContainer.nestedContainer(
                        keyedBy: DynamicKey.self, forKey: methodKey
                    )) != nil else { continue }
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

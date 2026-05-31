import Foundation
import MPPCore
import MPPDiscovery

/// Builds the two discovery surfaces the proxy publishes from its service tables: the spec
/// `/openapi.json` (via ``DiscoveryGenerator``) and a human/agent `/llms.txt` index.
enum ProxyDiscovery {
    /// The OpenAPI document advertising every route across `services`, as serialized JSON bytes.
    ///
    /// Each route is advertised at `/{serviceId}{pattern}` (basePath-prefixed): a gated route
    /// carries
    /// its declared `x-payment-info` and the spec-required `402`, a free route carries only its
    /// `200`. The root `x-service-info` aggregates the services' categories and links `llms` to the
    /// proxy's `/llms.txt`.
    static func openAPIJSON(
        services: [ProxyService],
        info: DiscoveryDocument.Info,
        basePath: String?
    ) throws -> Data {
        var routes: [DiscoveryRoute] = []
        for service in services {
            for route in service.routes {
                let path = withBasePath(basePath, "/\(service.id)\(route.pattern.openAPIPath())")
                routes.append(DiscoveryRoute(
                    path: path,
                    method: route.method,
                    payment: payment(of: route.endpoint),
                    requestBody: route.requestBody,
                    summary: route.summary
                ))
            }
        }
        let categories = aggregatedCategories(services)
        let serviceInfo = ServiceInfo(
            categories: categories.isEmpty ? nil : categories,
            docs: ServiceDocs(llms: withBasePath(basePath, "/llms.txt"))
        )
        let document = try DiscoveryGenerator.generate(
            info: info, routes: routes, serviceInfo: serviceInfo
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// The `/llms.txt` index: a title, description, the list of mounted services, and a link to the
    /// OpenAPI discovery document.
    static func llmsTxt(
        services: [ProxyService],
        title: String,
        description: String,
        basePath: String?
    ) -> String {
        var lines = ["# \(title)", "", "> \(description)", ""]
        guard !services.isEmpty else { return lines.joined(separator: "\n") }
        lines.append(contentsOf: ["## Services", ""])
        for service in services {
            lines.append("- \(service.id)")
        }
        lines.append("")
        lines.append("[OpenAPI discovery](\(withBasePath(basePath, "/openapi.json")))")
        return lines.joined(separator: "\n")
    }

    private static func payment(of endpoint: ProxyEndpoint) -> PaymentInfo? {
        switch endpoint {
        case .free: nil
        case let .paid(_, payment): payment
        }
    }

    private static func aggregatedCategories(_ services: [ProxyService]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for service in services {
            for category in service.categories where seen.insert(category).inserted {
                ordered.append(category)
            }
        }
        return ordered
    }

    /// Prefixes `path` with the normalized `basePath` (leading slash ensured, trailing slashes
    /// trimmed), or returns `path` unchanged when there is no base path.
    static func withBasePath(_ basePath: String?, _ path: String) -> String {
        guard let basePath, !basePath.isEmpty else { return path }
        let leading = basePath.hasPrefix("/") ? basePath : "/\(basePath)"
        let trimmed = leading.hasSuffix("/") ? String(leading.dropLast()) : leading
        return "\(trimmed)\(path)"
    }
}

import Foundation
import HTTPTypes
import MPPCore
import MPPDiscovery
import MPPServer

/// One upstream service the proxy fronts, mounted under `/{id}/` and gating a set of routes.
///
/// A service declares its origin (`baseURL`), the routes it exposes (each free or payment-gated),
/// and an optional `rewriteRequest` hook that injects the service's own upstream credentials after
/// the client request is scrubbed and before it is forwarded. The hook is the only place the proxy
/// authenticates to the origin: the client's `Payment` credential is always stripped first
/// (``ProxyHeaders/scrub(_:)``), so a client credential can never leak upstream.
public struct ProxyService: Sendable {
    /// The URL-prefix segment under which this service is mounted (`/{id}/...`).
    public let id: String
    /// The origin the service's routes are forwarded to (scheme + authority + optional base path).
    public let baseURL: URL
    /// The routes this service exposes, matched first-to-last.
    public let routes: [ProxyRoute]
    /// Categories advertised in the proxy's root `x-service-info`.
    public let categories: [String]
    /// Injects upstream credentials into the forwarded request (applied after scrub, before send).
    public let rewriteRequest: (@Sendable (HTTPRequest) -> HTTPRequest)?

    /// Creates a service with an explicit upstream-rewrite hook.
    public init(
        id: String,
        baseURL: URL,
        routes: [ProxyRoute],
        categories: [String] = [],
        rewriteRequest: (@Sendable (HTTPRequest) -> HTTPRequest)? = nil
    ) {
        self.id = id
        self.baseURL = baseURL
        self.routes = routes
        self.categories = categories
        self.rewriteRequest = rewriteRequest
    }

    /// Creates a service that injects `Authorization: Bearer {token}` upstream.
    public init(
        id: String,
        baseURL: URL,
        routes: [ProxyRoute],
        categories: [String] = [],
        bearer token: String
    ) {
        self.init(id: id, baseURL: baseURL, routes: routes, categories: categories) { request in
            var request = request
            request.headerFields[.authorization] = "Bearer \(token)"
            return request
        }
    }

    /// Creates a service that injects a fixed set of `headers` upstream.
    public init(
        id: String,
        baseURL: URL,
        routes: [ProxyRoute],
        categories: [String] = [],
        headers: [String: String]
    ) {
        self.init(id: id, baseURL: baseURL, routes: routes, categories: categories) { request in
            var request = request
            for (name, value) in headers {
                guard let fieldName = HTTPField.Name(name) else { continue }
                request.headerFields[fieldName] = value
            }
            return request
        }
    }
}

/// One route on a ``ProxyService``: an HTTP method + path pattern, free or payment-gated, plus the
/// metadata the proxy advertises for it in discovery.
public struct ProxyRoute: Sendable {
    /// The HTTP method this route matches.
    public let method: HTTPMethod
    /// The path pattern (relative to the service mount point) this route matches.
    public let pattern: RoutePattern
    /// Whether the route is free or gated, and (when gated) the gate + its advertised payment info.
    public let endpoint: ProxyEndpoint
    /// A short operation summary for discovery.
    public let summary: String?
    /// The OpenAPI `requestBody` object to advertise for this route, if any.
    public let requestBody: JSONValue?

    public init(
        method: HTTPMethod,
        pattern: RoutePattern,
        endpoint: ProxyEndpoint,
        summary: String? = nil,
        requestBody: JSONValue? = nil
    ) {
        self.method = method
        self.pattern = pattern
        self.endpoint = endpoint
        self.summary = summary
        self.requestBody = requestBody
    }
}

/// A route's payment disposition.
public enum ProxyEndpoint: Sendable {
    /// Forwarded upstream with no payment (the service's `rewriteRequest` still applies).
    case free
    /// Gated by `middleware`; `payment` is the `x-payment-info` advertised for it in discovery. The
    /// payment info is declared explicitly (rather than read from the gate's private binding) so
    /// the
    /// discovery contract stays declarative and the gate's internals stay private.
    case paid(MPPServerMiddleware, payment: PaymentInfo)
}

extension HTTPMethod {
    /// The discovery `HTTPMethod` for a swift-http-types request method, or `nil` if it is not one
    /// of
    /// the OpenAPI methods (`get`/`post`/...). Comparison is case-insensitive on the method token.
    init?(_ requestMethod: HTTPRequest.Method) {
        self.init(rawValue: requestMethod.rawValue.lowercased())
    }
}

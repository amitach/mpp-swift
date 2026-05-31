import Foundation
import HTTPTypes
import MPPClient
import MPPCore
import MPPDiscovery
import MPPServer

/// A framework-neutral 402-protected reverse proxy.
///
/// ``MPPProxy`` fronts one or more upstream ``ProxyService``s and gates their routes behind MPP
/// payment. It is pure request/response logic over `apple/swift-http-types` (the same currency
/// types
/// as ``MPPServerMiddleware`` and ``MPPHTTPTransport``), so it is hermetically testable and carries
/// no server dependency; binding it to a live socket is the job of a transport adapter (for example
/// `MPPHummingbird`), which feeds it a request + collected body and writes back its response.
///
/// For each request ``handle(_:body:now:)``:
/// 1. serves the discovery surfaces (`GET /openapi.json`, `GET /llms.txt`);
/// 2. routes `/{serviceId}/upstreamPath` to a service and its first matching route;
/// 3. for a free route, scrubs and forwards to the origin; for a gated route, runs the route's
///    ``MPPServerMiddleware`` (mint `402` / verify / attach `Payment-Receipt`) and forwards only on
///    a verified payment.
///
/// The client's `Authorization: Payment` credential is always stripped before forwarding
/// (``ProxyHeaders/scrub(_:)``); the origin is authenticated only by the service's `rewriteRequest`
/// hook. Because each gated route owns its own ``MPPServerMiddleware`` (hence its own
/// `RouteBinding`), a credential minted for one route is structurally rejected on another.
public struct MPPProxy: Sendable {
    private let services: [String: ProxyService]
    private let basePath: String?
    private let transport: any MPPHTTPTransport
    private let openAPIData: Data
    private let llmsText: String

    /// Creates a proxy over `services`.
    ///
    /// - Parameters:
    ///   - services: the upstream services to front, each mounted at `/{id}/`.
    ///   - info: the discovery document `info` (title + version).
    ///   - basePath: an optional path prefix stripped before routing and prefixed onto advertised
    ///     discovery paths (for example `/api/proxy`).
    ///   - transport: the seam used to forward to origins; defaults to ``URLSessionTransport``.
    ///   - title: the human title for `/llms.txt`; defaults to `info.title`.
    ///   - description: the `/llms.txt` description line.
    /// - Throws: if the discovery document cannot be generated from the route tables.
    public init(
        services: [ProxyService],
        info: DiscoveryDocument.Info,
        basePath: String? = nil,
        transport: any MPPHTTPTransport = URLSessionTransport(),
        title: String? = nil,
        description: String = "Paid API proxy powered by the Machine Payments Protocol."
    ) throws {
        self.services = Dictionary(
            services.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.basePath = basePath
        self.transport = transport
        openAPIData = try ProxyDiscovery.openAPIJSON(
            services: services,
            info: info,
            basePath: basePath
        )
        llmsText = ProxyDiscovery.llmsTxt(
            services: services, title: title ?? info.title, description: description,
            basePath: basePath
        )
    }

    /// Evaluates one request and produces its response.
    public func handle(
        _ request: HTTPRequest,
        body: Data,
        now: Date
    ) async -> (HTTPResponse, Data) {
        guard let rawPath = request.path, let pathname = strippedPathname(rawPath) else {
            return Self.notFound()
        }
        let (path, query) = Self.splitQuery(pathname)

        if request.method == .get, path == "/openapi.json" {
            return Self.dataResponse(openAPIData, contentType: "application/json")
        }
        if request.method == .get, path == "/llms.txt" {
            return Self.textResponse(llmsText)
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let serviceID = segments.first, let service = services[serviceID] else {
            return Self.notFound()
        }
        let upstreamSegments = Array(segments.dropFirst())
        guard let route = match(
            service: service,
            method: request.method,
            segments: upstreamSegments
        )
        else {
            return Self.notFound()
        }

        let upstreamPath = "/" + upstreamSegments.joined(separator: "/")
        switch route.endpoint {
        case .free:
            return await forward(request, body: body, to: service, path: upstreamPath, query: query)
        case let .paid(middleware, _):
            return await middleware.handle(request, body: body, now: now) { _, _ in
                await forward(request, body: body, to: service, path: upstreamPath, query: query)
            }
        }
    }

    // MARK: - Routing

    private func match(
        service: ProxyService, method: HTTPRequest.Method, segments: [String]
    ) -> ProxyRoute? {
        guard let httpMethod = HTTPMethod(method) else { return nil }
        return service.routes.first { route in
            route.method == httpMethod && route.pattern.match(segments) != nil
        }
    }

    private func strippedPathname(_ rawPath: String) -> String? {
        guard let basePath, !basePath.isEmpty else { return rawPath }
        let base = basePath.hasPrefix("/") ? basePath : "/\(basePath)"
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        if rawPath == trimmed { return "/" }
        guard rawPath.hasPrefix("\(trimmed)/") else { return nil }
        return String(rawPath.dropFirst(trimmed.count))
    }

    private static func splitQuery(_ pathname: String) -> (path: String, query: String) {
        guard let mark = pathname.firstIndex(of: "?") else { return (pathname, "") }
        return (String(pathname[..<mark]), String(pathname[mark...]))
    }

    // MARK: - Forwarding

    private func forward(
        _ request: HTTPRequest, body: Data, to service: ProxyService, path: String, query: String
    ) async -> (HTTPResponse, Data) {
        let upstreamPath = joinedUpstreamPath(base: service.baseURL, path: path) + query
        var upstream = HTTPRequest(
            method: request.method,
            scheme: service.baseURL.scheme ?? "https",
            authority: authority(of: service.baseURL),
            path: upstreamPath,
            headerFields: ProxyHeaders.scrub(request.headerFields)
        )
        if let rewrite = service.rewriteRequest {
            upstream = rewrite(upstream)
        }
        do {
            let (response, responseBody) = try await transport.send(upstream, body: body)
            var scrubbed = response
            scrubbed.headerFields = ProxyHeaders.scrubResponse(response.headerFields)
            return (scrubbed, responseBody)
        } catch {
            return Self.badGateway()
        }
    }

    /// Joins the origin's base path with the upstream request path (the peer's "join upstream base
    /// paths with request paths"): a base URL of `https://host/v1` and a request path of `/models`
    /// forward to `/v1/models`. A root base path (`/` or empty) leaves the request path unchanged.
    private func joinedUpstreamPath(base: URL, path: String) -> String {
        let basePath = base.path
        guard !basePath.isEmpty, basePath != "/" else { return path }
        let trimmed = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        return "\(trimmed)\(path)"
    }

    private func authority(of url: URL) -> String {
        let host = url.host ?? ""
        return url.port.map { "\(host):\($0)" } ?? host
    }

    // MARK: - Responses

    private static func notFound() -> (HTTPResponse, Data) {
        (HTTPResponse(status: .notFound), Data("Not Found".utf8))
    }

    private static func badGateway() -> (HTTPResponse, Data) {
        (HTTPResponse(status: .badGateway), Data("Bad Gateway".utf8))
    }

    private static func dataResponse(_ data: Data, contentType: String) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = contentType
        response.headerFields[.cacheControl] = "public, max-age=300"
        return (response, data)
    }

    private static func textResponse(_ text: String) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "text/plain; charset=utf-8"
        return (response, Data(text.utf8))
    }
}

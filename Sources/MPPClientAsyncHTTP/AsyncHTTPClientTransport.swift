import AsyncHTTPClient
import Foundation
import HTTPTypes
import MPPClient
import NIOCore
import NIOHTTP1

/// An ``MPPHTTPTransport`` backed by `swift-server/async-http-client`.
///
/// This is the server-side / Linux-native counterpart to ``URLSessionTransport``: the same 402
/// flow runs over it unchanged, but the round-trip is served by `AsyncHTTPClient`'s SwiftNIO client
/// (connection pooling, no `FoundationNetworking` quirks) -- the transport a long-lived broker or
/// gateway process wants. It performs only the network round-trip; the `PaymentClient` flow owns
/// 402 detection, challenge selection, credential building, the retry, and the transport-security
/// policy (https-only with the `allowInsecureLocal` loopback opt-in, enforced in `PaymentClient`
/// before any request reaches a transport).
///
/// **Redirects are not followed.** `AsyncHTTPClient`'s default configuration *does* follow up to
/// five redirects, which -- exactly as with `URLSession` -- could let a server `30x` the flow to a
/// different (or downgraded `http`) destination and carry the `Authorization: Payment` credential
/// there, behind the client's https check. The owned client is therefore configured with
/// `RedirectConfiguration.disallow` so a `30x` surfaces to the caller, which re-applies its own
/// policy. An injected client owns its own redirect policy; inject one only if it disallows them
/// the same way.
///
/// - Important: a non-singleton `HTTPClient` must be shut down before it is dropped or it traps in
///   `deinit`. This transport therefore owns its client explicitly and exposes an async
///   ``shutdown()``; await it once the transport is no longer needed. An *injected* client is left
///   untouched -- its owner shuts it down.
public final class AsyncHTTPClientTransport: MPPHTTPTransport {
    private let client: HTTPClient
    private let ownsClient: Bool
    private let requestTimeout: TimeAmount
    private let maxResponseBytes: Int

    /// Creates a transport that owns a private, redirect-disallowing ``HTTPClient`` over SwiftNIO's
    /// shared singleton event-loop group.
    ///
    /// - Parameters:
    ///   - requestTimeout: the deadline for a single round-trip. Defaults to 60 seconds.
    ///   - maxResponseBytes: the cap on a response body collected into memory, a guard against an
    ///     unbounded download. Defaults to 50 MiB; raise it for a transport that fetches larger
    ///     paid payloads.
    /// - Important: pair this with ``shutdown()`` -- the owned client traps if dropped un-shut.
    public init(
        requestTimeout: TimeAmount = .seconds(60),
        maxResponseBytes: Int = 50 * 1024 * 1024
    ) {
        client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: HTTPClient.Configuration(redirectConfiguration: .disallow)
        )
        ownsClient = true
        self.requestTimeout = requestTimeout
        self.maxResponseBytes = maxResponseBytes
    }

    /// Creates a transport over an injected `client` (for a process that already owns one, or a
    /// custom TLS / proxy configuration). The injected client's lifecycle and redirect policy are
    /// the caller's; ``shutdown()`` is a no-op for it.
    ///
    /// - Warning: configure the injected client to disallow redirects -- the default follows up to
    ///   five. Otherwise a `30x` could carry the payment credential to a different host, behind the
    ///   flow's https check.
    public init(
        client: HTTPClient,
        requestTimeout: TimeAmount = .seconds(60),
        maxResponseBytes: Int = 50 * 1024 * 1024
    ) {
        self.client = client
        ownsClient = false
        self.requestTimeout = requestTimeout
        self.maxResponseBytes = maxResponseBytes
    }

    /// Shuts down the owned ``HTTPClient``; a no-op for an injected client (its owner shuts it
    /// down). Safe to call once -- calling it again after shutdown traps, like the client itself.
    public func shutdown() async throws {
        if ownsClient { try await client.shutdown() }
    }

    public func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        guard let scheme = request.scheme, let authority = request.authority else {
            throw AsyncHTTPClientTransportError.unroutableRequest
        }
        var outbound = HTTPClientRequest(url: "\(scheme)://\(authority)\(request.path ?? "")")
        outbound.method = HTTPMethod(rawValue: request.method.rawValue)
        for field in request.headerFields {
            outbound.headers.add(name: field.name.canonicalName, value: field.value)
        }
        if !body.isEmpty { outbound.body = .bytes(body) }

        let response = try await client.execute(outbound, timeout: requestTimeout)
        let collected = try await response.body.collect(upTo: maxResponseBytes)
        return (Self.mapResponse(response), Data(collected.readableBytesView))
    }

    /// Maps an `AsyncHTTPClient` response head (NIO `HTTPResponseStatus` + `HTTPHeaders`) onto the
    /// framework-neutral `HTTPResponse` the flow reads. `append` preserves repeated fields (several
    /// `WWW-Authenticate` lines, `Set-Cookie`), which the 402 challenge parser relies on.
    private static func mapResponse(_ response: HTTPClientResponse) -> HTTPResponse {
        var fields = HTTPFields()
        for header in response.headers {
            guard let name = HTTPField.Name(header.name) else { continue }
            fields.append(HTTPField(name: name, value: header.value))
        }
        return HTTPResponse(status: .init(code: Int(response.status.code)), headerFields: fields)
    }
}

/// A reason ``AsyncHTTPClientTransport`` could not send a request; a lower-level `HTTPClient`
/// failure (connection, TLS, timeout) propagates unwrapped instead.
public enum AsyncHTTPClientTransportError: Error, Sendable, Hashable {
    /// The request lacked a `scheme` or `authority`, so no absolute URL could be formed. The 402
    /// flow's own security gate requires both before a request reaches a transport, so this is a
    /// guard against a hand-built request, not a path the flow takes.
    case unroutableRequest
}

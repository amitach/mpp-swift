import Foundation
import HTTPTypes
import HTTPTypesFoundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An ``MPPHTTPTransport`` backed by `URLSession` (the default transport on
/// Apple platforms; also works on Linux via `FoundationNetworking`).
///
/// It performs only the network round-trip: the `PaymentClient` flow owns 402
/// detection, challenge selection, credential building, the retry, and the
/// transport-security policy (https-only with the `allowInsecureLocal` loopback
/// opt-in is enforced in `PaymentClient` before any request reaches a transport).
///
/// **Redirects are not followed.** `URLSession` follows redirects by default,
/// which would let a server `30x` the flow to a different (or downgraded `http`)
/// destination and carry the `Authorization: Payment` credential there, behind
/// the client's https check. The default session blocks redirects so a `30x`
/// surfaces to the caller, which re-applies its own policy. To pin a minimum TLS
/// version, inject a `URLSession` configured with `tlsMinimumSupportedProtocolVersion`
/// (Apple); injected sessions own their own redirect policy.
public struct URLSessionTransport: MPPHTTPTransport {
    private let session: URLSession

    /// Creates a transport over a private session that does not follow redirects.
    public init() {
        session = Self.nonRedirectingSession
    }

    /// Creates a transport over an injected `session` (for tests or a custom
    /// configuration). The injected session owns its own redirect behaviour.
    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: HTTPRequest, body: Data) async throws -> (HTTPResponse, Data) {
        // HTTPTypesFoundation maps HTTPRequest <-> URLRequest and HTTPURLResponse ->
        // HTTPResponse. `data(for:)` sends no body; `upload(for:from:)` carries one.
        if body.isEmpty {
            let (data, response) = try await session.data(for: request)
            return (response, data)
        }
        let (data, response) = try await session.upload(for: request, from: body)
        return (response, data)
    }

    // One process-lifetime session (delegate sessions must not be created per
    // instance: an un-invalidated delegate session leaks). Stateless delegate.
    private static let nonRedirectingSession = URLSession(
        configuration: .ephemeral,
        delegate: RedirectBlocker(),
        delegateQueue: nil
    )
}

/// Refuses HTTP redirects so the `30x` is returned to the caller rather than
/// silently followed (preventing a host change or `https` -> `http` downgrade
/// from carrying the payment credential).
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

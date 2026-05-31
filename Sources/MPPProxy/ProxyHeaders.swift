import HTTPTypes

/// Header hygiene applied as a request crosses the proxy boundary, in both directions.
///
/// A reverse proxy must not blindly relay every header. ``scrub(_:)`` cleans a client request
/// before it is forwarded upstream; ``scrubResponse(_:)`` cleans the upstream response before it is
/// returned to the client. The sets are deliberately conservative and security-motivated, not
/// transport-incidental.
enum ProxyHeaders {
    /// Hop-by-hop headers (RFC 9110 §7.6.1): they govern a single transport connection and must not
    /// be forwarded across the proxy to a different connection.
    private static let hopByHop: Set<String> = [
        "connection", "keep-alive", "transfer-encoding", "upgrade",
        "proxy-authenticate", "proxy-authorization", "te", "trailer",
    ]

    /// Strips hop-by-hop, credential, encoding, cookie, and forwarding headers from a client
    /// request
    /// before it is sent upstream.
    ///
    /// - `authorization` is dropped so the client's `Payment` credential is never leaked to the
    ///   origin; the origin is authenticated separately (the service's `rewriteRequest` hook).
    /// - `cookie` is dropped so a browser's cookies for the proxy origin never reach the upstream.
    /// - `content-length` is dropped because the forwarding transport sets it for the body it
    /// sends.
    /// - `accept-encoding` is dropped so the upstream returns an unencoded body the proxy can relay
    ///   without having to decode it.
    /// - `x-forwarded-*` headers are dropped so a client cannot spoof its apparent origin to the
    ///   upstream through the proxy.
    static func scrub(_ headers: HTTPFields) -> HTTPFields {
        var scrubbed = HTTPFields()
        for field in headers {
            let name = field.name.canonicalName
            if name == "authorization" || name == "accept-encoding"
                || name == "content-length" || name == "cookie"
                || hopByHop.contains(name) || name.hasPrefix("x-forwarded-") {
                continue
            }
            scrubbed.append(field)
        }
        return scrubbed
    }

    /// Strips re-streaming and security-sensitive headers from an upstream response before it is
    /// returned to the client.
    ///
    /// - `content-encoding` and `content-length` are dropped because the proxy re-streams the body
    ///   and the values would no longer describe the bytes the client receives.
    /// - `set-cookie` is dropped because a paid API proxy must never let an upstream set cookies in
    ///   the client's browser under the proxy's origin. A compromised or attacker-influenced
    /// upstream
    ///   returning `Set-Cookie: session=evil; Domain=.proxy.example` would have the browser honor
    /// it
    ///   for every sibling subdomain of the proxy, turning any path-confusion or open-redirect bug
    /// in
    ///   the surrounding deployment into a session-fixation primitive. Proxied services
    /// authenticate
    ///   via bearer tokens / signed payloads, never cookies, so dropping it is purely defensive.
    static func scrubResponse(_ headers: HTTPFields) -> HTTPFields {
        var scrubbed = HTTPFields()
        for field in headers {
            let name = field.name.canonicalName
            if name == "content-encoding" || name == "content-length" || name == "set-cookie" {
                continue
            }
            scrubbed.append(field)
        }
        return scrubbed
    }
}

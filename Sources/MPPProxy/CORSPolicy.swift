/// An opt-in CORS policy for the proxy's public discovery surfaces (`GET /openapi.json`,
/// `GET /llms.txt`).
///
/// The discovery spec SHOULDs (§6.3) that discovery documents be fetchable cross-origin, so a
/// browser-based agent can read them. The reference peer emits no CORS headers and leaves the
/// choice to the deploying app, so this SDK does the same **by default**: with no policy the
/// discovery responses are byte-identical to before. Setting a policy opts in: it adds the
/// access-control headers to the two discovery responses and answers their `OPTIONS` preflight.
///
/// The policy applies **only** to the discovery surfaces, never to proxied upstream routes: a
/// gated/free route forwards the origin's own response untouched, and cross-origin access to it is
/// the origin's concern.
public struct CORSPolicy: Sendable {
    /// The value emitted for `Access-Control-Allow-Origin`: typically `"*"` for the public,
    /// unauthenticated discovery docs, or a single specific origin.
    public let allowOrigin: String

    /// - Parameter allowOrigin: the `Access-Control-Allow-Origin` value (for example `"*"` or
    ///   `"https://app.example.com"`).
    public init(allowOrigin: String) {
        self.allowOrigin = allowOrigin
    }

    /// Allow any origin (`Access-Control-Allow-Origin: *`): the natural choice for the public,
    /// unauthenticated discovery documents.
    public static let allowAnyOrigin = CORSPolicy(allowOrigin: "*")

    /// Whether this policy names a single specific origin (so a cache must `Vary: Origin`) rather
    /// than the wildcard.
    var isOriginSpecific: Bool {
        allowOrigin != "*"
    }
}

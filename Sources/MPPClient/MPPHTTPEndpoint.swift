import Foundation

/// Derives an HTTP-request `authority` and a redacted endpoint string from a URL.
///
/// The single home for two easy-to-get-wrong derivations every client that posts
/// over ``MPPHTTPTransport`` needs: bracketing an IPv6 literal host for the
/// `authority` (dropping the brackets corrupts the authority for a `[::1]`-style
/// host), and a path/query-stripped endpoint string for an error message that
/// must not leak an API key. Path and query rules stay with each caller.
public struct MPPHTTPEndpoint: Sendable, Hashable {
    /// The endpoint URL.
    public let url: URL

    /// Wraps an endpoint URL.
    public init(_ url: URL) {
        self.url = url
    }

    /// The `authority` (host, or host:port) for an `HTTPTypes` request, bracketing
    /// an IPv6 literal host (`::1` becomes `[::1]`).
    public var authority: String {
        let host = url.host(percentEncoded: false) ?? ""
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(bracketed):\($0)" } ?? bracketed
    }

    /// The `scheme://host` form with no path or query: identifies the endpoint for
    /// an error message without leaking an API key that may live in the path/query.
    public var redactedEndpoint: String {
        "\(url.scheme ?? "")://\(url.host(percentEncoded: false) ?? "")"
    }
}

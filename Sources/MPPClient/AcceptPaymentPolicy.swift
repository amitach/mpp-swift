import Foundation

/// Controls when the client advertises payment support by sending an
/// `Accept-Payment` request header, and so which origins it is willing to pay.
///
/// Without a gate, a payment-aware client would advertise on every request,
/// including cross-origin ones, which can trip CORS preflight on servers that
/// know nothing about payment. The default in most clients is therefore to
/// restrict advertising; this policy makes the choice explicit. Origins are
/// compared per RFC 6454 (`scheme`, host, and effective port).
public enum AcceptPaymentPolicy: Sendable, Hashable {
    /// Advertise on every request.
    case always
    /// Never advertise.
    case never
    /// Advertise only when the request URL has the same origin as this reference
    /// URL: equal `scheme`, host, and effective port.
    case sameOrigin(URL)
    /// Advertise only when the request URL matches one of these patterns: an
    /// exact origin (`https://app.example.com`, optionally with a port) or a
    /// `*.host` subdomain wildcard, which also matches the bare `host`.
    case origins([String])

    /// Whether the `Accept-Payment` header may be sent for a request to `url`.
    ///
    /// A `url` without a scheme or host (or with a scheme that has no known
    /// default port and no explicit port) fails origin comparison and is not
    /// advertised to, except under ``always``.
    public func allows(_ url: URL) -> Bool {
        switch self {
        case .always:
            return true
        case .never:
            return false
        case let .sameOrigin(reference):
            guard let requestOrigin = Self.origin(of: url),
                  let referenceOrigin = Self.origin(of: reference)
            else { return false }
            return requestOrigin == referenceOrigin
        case let .origins(patterns):
            return patterns.contains { Self.matches(url, pattern: $0) }
        }
    }

    /// Whether `url` matches a single `.origins` pattern.
    private static func matches(_ url: URL, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            // Host-only subdomain wildcard, ignoring scheme/port (mirrors both refs).
            let suffix = String(pattern.dropFirst(2)).lowercased()
            guard !suffix.isEmpty, let host = url.host(percentEncoded: false)?.lowercased() else {
                return false
            }
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        // Exact origin: parse the pattern as a URL and compare origins.
        guard let patternOrigin = URL(string: pattern).flatMap(origin(of:)),
              let requestOrigin = origin(of: url)
        else { return false }
        return requestOrigin == patternOrigin
    }

    /// The RFC 6454 origin of `url` as `scheme://host:port`, lowercased, with the
    /// scheme's default port filled in. `nil` if `url` lacks a scheme or host, or
    /// the scheme has no known default port and no explicit port.
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased(),
              let port = url.port ?? defaultPort(for: scheme)
        else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

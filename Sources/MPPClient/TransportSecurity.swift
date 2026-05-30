import Foundation

/// The one transport-security policy for the SDK: production is `https`-only, with
/// an explicit `allowInsecureLocal` opt-in that permits plain `http` to a loopback
/// host (`localhost`, `*.localhost`, `127.0.0.1`, `::1`) for tests and local
/// servers. Shared so the 402 flow and the EVM JSON-RPC client enforce the same
/// rule rather than two policies that could drift.
public enum TransportSecurity {
    /// Whether a request to `scheme`/`host` is permitted: `https` always; plain
    /// `http` only to a loopback host when `allowInsecureLocal` is set.
    public static func isAllowed(
        scheme: String?, host: String?, allowInsecureLocal: Bool
    ) -> Bool {
        if scheme?.lowercased() == "https" { return true }
        if allowInsecureLocal, let host, isLoopback(host) { return true }
        return false
    }

    /// The loopback hosts that `allowInsecureLocal` permits over plain `http`.
    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "127.0.0.1" || host == "::1"
    }
}

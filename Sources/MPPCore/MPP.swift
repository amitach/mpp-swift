/// The Machine Payments Protocol (MPP) Swift SDK.
///
/// MPP standardizes machine-to-machine payments over HTTP 402 (and JSON-RPC/MCP
/// and WebSocket) using a challenge → credential → receipt flow. `MPPCore`
/// provides the protocol primitives shared by both the client (paying) and
/// server (charging) sides; higher-level modules build on it.
///
/// This SDK is the canonical Swift implementation of the protocol. It targets
/// the IETF "Payment" authentication scheme and the related drafts published at
/// <https://paymentauth.org>.
public enum MPP {
    /// The semantic version of this SDK release.
    public static let version = "0.0.1"

    /// The MPP specification drafts this release targets.
    ///
    /// The SDK defaults to spec-correct behavior. Where the reference SDKs
    /// (`mppx`, `mpp-rs`) diverge from these drafts, the divergence is handled
    /// explicitly via the compatibility configuration rather than silently
    /// inherited.
    public static let supportedSpecifications: [String] = [
        "draft-httpauth-payment-00",
        "draft-payment-intent-charge-00",
        "draft-payment-transport-mcp-00",
        "draft-payment-discovery-00",
        "draft-tempo-charge-00",
        "draft-tempo-session-00",
    ]
}

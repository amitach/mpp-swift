/// Wire constants for the MPP "Payment" authentication scheme bound to JSON-RPC / Model Context
/// Protocol, per `draft-payment-transport-mcp-00` (paymentauth.org).
///
/// These are the JSON-RPC error codes and the `_meta` / `error.data` keys the transport binding
/// uses; the `_meta` / `error.data` keys match the reference implementation (mppx).
public enum MCPPayment {
    /// JSON-RPC error code for "payment required" (server error range, -32000 to -32099),
    /// raised when no credential was supplied. In ``MCPErrorCodeMode/peerCompatible`` it is
    /// ALSO raised for a supplied-but-rejected credential; see that mode and ``MCPErrorCodeMode``.
    public static let paymentRequiredCode = -32042

    /// The spec's "payment verification failed" code (`draft-payment-transport-mcp-00` §10.1),
    /// raised for a supplied-but-rejected credential in ``MCPErrorCodeMode/specCorrect``. The
    /// default ``MCPErrorCodeMode/peerCompatible`` mode emits ``paymentRequiredCode`` instead.
    public static let verificationFailedCode = -32043

    /// `_meta` key carrying the credential on a request (`params._meta`). Reverse-DNS namespaced
    /// to avoid collisions.
    public static let credentialMetaKey = "org.paymentauth/credential"

    /// `_meta` key carrying the receipt on a result (`result._meta`).
    public static let receiptMetaKey = "org.paymentauth/receipt"
}

/// Selects the JSON-RPC error code the MCP payment gate emits on a payment-required
/// re-challenge: the compatibility switch for the audit-D1 divergence.
///
/// DIVERGING_FROM_SPEC (audit D1): `draft-payment-transport-mcp-00` §10.1 assigns
/// ``MCPPayment/verificationFailedCode`` (-32043) to a supplied credential that failed
/// verification and ``MCPPayment/paymentRequiredCode`` (-32042) only to an absent one. The mppx
/// reference client recognizes only -32042 (it treats -32043 as a non-payment error and does not
/// retry), so the default matches the peer. Select ``specCorrect`` to emit the spec codes (for a
/// peer that adopts them).
public enum MCPErrorCodeMode: Sendable {
    /// Emit ``MCPPayment/paymentRequiredCode`` (-32042) for BOTH an absent and a
    /// failed-verification credential, matching the mppx peer. The default.
    case peerCompatible
    /// Emit ``MCPPayment/paymentRequiredCode`` (-32042) when no credential was supplied and
    /// ``MCPPayment/verificationFailedCode`` (-32043) when one was supplied but failed, per
    /// `draft-payment-transport-mcp-00` §10.1.
    case specCorrect
}

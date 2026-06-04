/// Wire constants for the MPP "Payment" authentication scheme bound to JSON-RPC / Model Context
/// Protocol, per `draft-payment-transport-mcp-00` (paymentauth.org).
///
/// These are the JSON-RPC error codes and the `_meta` / `error.data` keys the transport binding
/// uses; the `_meta` / `error.data` keys match the reference implementation (mppx).
public enum MCPPayment {
    /// JSON-RPC error code the server raises both for "payment required" and for a
    /// supplied credential that failed verification (server error range, -32000 to -32099).
    ///
    /// DIVERGING_FROM_SPEC (audit D1): `draft-payment-transport-mcp-00` §10.1 assigns a
    /// separate code (-32043, ``verificationFailedCode``) to a failed verification, but the
    /// mppx reference client only recognizes -32042 - it treats -32043 as a non-payment
    /// error and does not retry - so the server emits -32042 for both to stay interoperable
    /// with the peer. Revisit (emit -32043 on failure) if the peer adopts the spec code.
    public static let paymentRequiredCode = -32042

    /// The spec's "payment verification failed" code (`draft-payment-transport-mcp-00` §10.1).
    /// Kept as the documented spec value, but NOT emitted by this server: see the
    /// DIVERGING_FROM_SPEC note on ``paymentRequiredCode``.
    public static let verificationFailedCode = -32043

    /// `_meta` key carrying the credential on a request (`params._meta`). Reverse-DNS namespaced
    /// to avoid collisions.
    public static let credentialMetaKey = "org.paymentauth/credential"

    /// `_meta` key carrying the receipt on a result (`result._meta`).
    public static let receiptMetaKey = "org.paymentauth/receipt"
}

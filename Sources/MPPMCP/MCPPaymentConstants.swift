/// Wire constants for the MPP "Payment" authentication scheme bound to JSON-RPC / Model Context
/// Protocol, per `draft-payment-transport-mcp-00` (paymentauth.org).
///
/// These are the JSON-RPC error codes and the `_meta` / `error.data` keys the transport binding
/// uses; the reference implementation (mppx) uses the same values, so they are the interop
/// contract.
public enum MCPPayment {
    /// JSON-RPC error code signalling "payment required" (in the implementation-defined server
    /// error range, -32000 to -32099).
    public static let paymentRequiredCode = -32042

    /// JSON-RPC error code signalling "payment verification failed".
    public static let verificationFailedCode = -32043

    /// `_meta` key carrying the credential on a request (`params._meta`). Reverse-DNS namespaced
    /// to avoid collisions.
    public static let credentialMetaKey = "org.paymentauth/credential"

    /// `_meta` key carrying the receipt on a result (`result._meta`).
    public static let receiptMetaKey = "org.paymentauth/receipt"
}

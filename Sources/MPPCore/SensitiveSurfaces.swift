/// The named surfaces that carry a secret value across the protocol, gathered in one place so a
/// logging, tracing, or capture consumer can redact all of them consistently, and so a newly
/// added secret-bearing surface is registered here once rather than rediscovered per call site.
///
/// The surfaces:
/// - ``credentialHeader`` (`Authorization`): the request header carrying a client's `Payment`
///   credential (the Shared Payment Token or signed proof).
/// - ``receiptHeader`` (`Payment-Receipt`): the response header carrying the settlement
/// ``Receipt``.
/// - ``currentSecretEnvironmentVariable`` / ``previousSecretEnvironmentVariable``
///   (`MPP_SECRET_KEY` / `MPP_SECRET_KEY_PREVIOUS`): the HMAC signing key(s).
///
/// This is the canonical list: the server's secret loader and its `Payment-Receipt` header derive
/// their names from here, so the registry cannot drift from what the SDK actually emits or reads.
///
/// It performs no redaction itself; it only names the surfaces. A consumer compares header names
/// **case-insensitively** (per RFC 9110 §5.1) when matching against ``headerNames``.
public enum MPPSensitiveSurfaces {
    /// The request header carrying a client's `Payment` credential (the SPT or signed proof bytes).
    public static let credentialHeader = "Authorization"

    /// The response header carrying the settlement ``Receipt``.
    public static let receiptHeader = "Payment-Receipt"

    /// The environment variable holding the current HMAC signing secret.
    public static let currentSecretEnvironmentVariable = "MPP_SECRET_KEY"

    /// The environment variable holding comma-separated previous (rotation-overlap) signing
    /// secrets.
    public static let previousSecretEnvironmentVariable = "MPP_SECRET_KEY_PREVIOUS"

    /// Every header field name that may carry a secret value, for a header-redaction pass. Match
    /// case-insensitively (RFC 9110 §5.1).
    public static let headerNames: [String] = [credentialHeader, receiptHeader]

    /// Every environment-variable name that holds a secret, for an environment-redaction pass.
    public static let environmentVariableNames: [String] = [
        currentSecretEnvironmentVariable,
        previousSecretEnvironmentVariable,
    ]
}

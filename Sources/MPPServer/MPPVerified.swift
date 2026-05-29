import MPPCore

/// Proof that a request carried a protocol-valid `Authorization: Payment`
/// credential: the echoed challenge is one this server signed, it has not
/// expired, the request body matches the challenge digest (if any), and the
/// challenge id was consumed exactly once.
///
/// Only ``PaymentVerifier`` can produce a value, so a protected handler typed
/// `(Request, MPPVerified) -> Response` structurally cannot run without payment
/// having been verified: the unpaid path has no way to obtain this token.
///
/// Unforgeability rests on the memberwise initializer being synthesized
/// `internal` (Swift never synthesizes a `public` one), so only this module can
/// construct a token. Do NOT add a `public init`, or the unpaid path could
/// fabricate one and bypass verification.
///
/// This attests the protocol-level checks. When a payment method settled the
/// credential, ``receipt`` carries the `Payment-Receipt` the verifier minted from
/// the method's settlement reference; in protocol-only mode (no method registered)
/// it is `nil`.
public struct MPPVerified: Sendable {
    /// The verified credential: its echoed challenge, the payer `source`, and the
    /// method-specific `payload`.
    public let credential: Credential
    /// The settlement receipt minted when a payment method verified the credential
    /// (the `Payment-Receipt` the server returns); `nil` in protocol-only
    /// verification, where no method settled the payment.
    public let receipt: Receipt?
}

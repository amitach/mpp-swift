import MPPCore

/// Proof that a request is authorized to run a payment-protected handler: either it
/// carried a protocol-valid `Authorization: Payment` credential (the echoed challenge
/// is one this server signed, un-expired, the body matches the digest if any, and the
/// challenge id was consumed exactly once), or it was authorized by an
/// operator-configured ``RequestAuthorizer`` against an established grant (a returning
/// subscriber recognized without a per-request credential).
///
/// Only this module produces a value: ``PaymentVerifier`` on the credential path, and
/// ``MPPServerMiddleware`` lifting a ``RequestAuthorizer``'s receipt on the
/// credential-less path. A protected handler typed `(Request, MPPVerified) -> Response`
/// therefore structurally cannot run unauthorized: no other code can obtain this token.
///
/// Unforgeability rests on the memberwise initializer being synthesized `internal`
/// (Swift never synthesizes a `public` one), so only this module can construct a token.
/// Do NOT add a `public init`, or an unauthorized path could fabricate one and bypass
/// verification. The authorize path does not weaken this: the authorizer returns only a
/// receipt and is configured by the operator (like the verifier); the middleware, not the
/// authorizer, mints the token, and a middleware with no authorizer still answers `402`.
///
/// When a payment method settled the credential (or a subscription renewal charged on the
/// authorize path), ``receipt`` carries the `Payment-Receipt`; in protocol-only mode it is `nil`.
public struct MPPVerified: Sendable {
    /// The verified credential, or `nil` when this token came from the credential-less
    /// authorize path (a returning subscriber): there is a settlement ``receipt`` but no
    /// per-request credential. Always set on the ``PaymentVerifier`` credential path.
    public let credential: Credential?
    /// The settlement receipt minted when a payment method verified the credential, or a
    /// subscription renewal charged on the authorize path (the `Payment-Receipt` the
    /// server returns); `nil` in protocol-only verification, where no value was settled.
    public let receipt: Receipt?
}

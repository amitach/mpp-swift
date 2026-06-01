import MPPCore

/// A client-side payment method: it recognises the challenges it can pay and
/// builds the `Authorization: Payment` credential for one.
///
/// The 402 flow is method-agnostic. It selects an offered challenge that some
/// registered method ``supports(_:)`` and delegates credential construction to
/// that method, exactly as the reference SDKs route by method. The concrete
/// methods (Tempo charge, Stripe, …) and their signing/settlement live in their
/// own workstreams; this is the seam the flow depends on.
public protocol PaymentMethodClient: Sendable {
    /// Whether this method can pay `challenge` (typically a `method`-name match,
    /// plus any method-specific applicability the method enforces).
    func supports(_ challenge: Challenge) -> Bool

    /// Builds the credential to present for `challenge`.
    ///
    /// Throws if the method cannot build a credential (for example the challenge
    /// is malformed for this method, or signing material is unavailable); the
    /// flow propagates that error to the caller unwrapped.
    func buildCredential(for challenge: Challenge) async throws -> Credential

    /// The vendor-neutral approval facts for `challenge`, surfaced to a
    /// ``PaymentAuthorizer`` before the credential is built.
    ///
    /// The default returns the rail-agnostic facts on the challenge alone
    /// (``PaymentApprovalRequest/init(generic:)``), leaving amount/currency/
    /// recipient `nil`. A method that can decode those from the challenge's
    /// method-specific `request` overrides this to fill them, so a spending cap or
    /// a user prompt sees the real amount. It does no signing and must not throw:
    /// a request it cannot decode falls back to the generic facts.
    func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest
}

public extension PaymentMethodClient {
    /// The rail-agnostic default: the facts available on the challenge alone.
    func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest {
        PaymentApprovalRequest(generic: challenge)
    }
}

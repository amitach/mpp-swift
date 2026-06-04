import MPPCore

/// An observable moment in the server's payment flow, delivered to the sink a
/// ``MPPServerMiddleware`` was created with.
///
/// Diagnostics and metrics only: emitting an event never changes the protocol
/// decision, and the sink runs synchronously inside the request path, so a
/// handler should be cheap (hand off to a logger/metrics queue, do not block).
public enum ServerEvent: Sendable {
    /// A challenge was minted and returned in a `402`: either because the request
    /// carried no credential, or as the retry challenge that accompanies a `402`
    /// rejection. A terminal §10.5 settlement problem (`410` / `400`) offers no retry
    /// challenge, so it fires only ``paymentRejected(_:)`` and no `challengeIssued`. On a
    /// rejection this event follows ``paymentRejected(_:)`` for the same request.
    case challengeIssued(Challenge)
    /// A credential verified; the protected handler is about to run.
    case paymentVerified(MPPVerified)
    /// A presented credential was rejected. A `402` returns a fresh retry challenge; a terminal
    /// §10.5 settlement problem (`410` / `400`) returns the problem with no challenge.
    case paymentRejected(PaymentVerifier.Rejection)
}

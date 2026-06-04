/// A typed settlement rejection: the RFC 9457 problem and HTTP status a payment method wants the
/// transport to answer with, per `draft-httpauth-payment-00` §10.5.
///
/// Without this, every method settlement failure collapses to a single generic `402` /
/// `verification-failed`. A method whose `verify` throws an error conforming to
/// ``SettlementProblemConvertible`` instead carries a precise problem: a distinct type (for a
/// session, the `session/...` family), a human title, the right status (e.g. `410` for a closed
/// or unknown channel, `400` for a malformed request, `402` for a payment-amount or signature
/// failure), and a client-safe detail. ``PaymentVerifier`` surfaces it as
/// ``PaymentVerifier/Rejection/settlement(_:)`` and the middleware renders it into the `402`/`410`/
/// `400` response.
public struct SettlementProblem: Sendable, Hashable {
    /// The problem `type` slug, appended to `https://paymentauth.org/problems/`. May include a
    /// family segment, e.g. `session/invalid-signature`.
    public let slug: String
    /// The human-readable problem title.
    public let title: String
    /// The HTTP status the transport answers with (e.g. `402`, `410`, `400`).
    public let status: Int
    /// A client-safe one-line detail. Must not carry a secret (it is echoed to the client).
    public let detail: String

    public init(slug: String, title: String, status: Int, detail: String) {
        self.slug = slug
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// An error a ``PaymentMethodServer`` can throw to surface a typed ``SettlementProblem`` (its
/// RFC 9457 problem type and HTTP status) rather than collapse to a generic verification failure.
/// An error that does not conform falls back to
/// ``PaymentVerifier/Rejection/settlementUnverified(reason:)``.
public protocol SettlementProblemConvertible: Error {
    var settlementProblem: SettlementProblem { get }
}

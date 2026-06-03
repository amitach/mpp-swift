import Foundation
import HTTPTypes
import MPPCore

/// Authorizes a credential-less request against an already-established grant (for example a
/// returning
/// subscriber recognized by app-level identity), so a payment-protected route can serve a repeat
/// caller without minting a fresh `402`.
///
/// ``MPPServerMiddleware`` consults its authorizer ONLY when a request carries no `Authorization`
/// credential, before minting the `402` challenge. An operator opts in by passing an authorizer at
/// middleware construction (a trusted seam, like the verifier); a middleware with no authorizer
/// answers `402` for every credential-less request, so this adds no bypass. The authorizer returns
/// a
/// receipt-based ``AuthorizeOutcome``; ``MPPServerMiddleware`` (the only minter of ``MPPVerified``)
/// lifts an ``AuthorizeOutcome/authorized(_:)`` into a credential-less token and runs the handler.
public protocol RequestAuthorizer: Sendable {
    /// Decides a credential-less request, or returns `nil` to fall through to the `402`/verify
    /// path.
    ///
    /// - Parameters:
    ///   - request: the incoming request (the authorizer resolves the caller's identity from it).
    ///   - body: the full request body, already within the middleware's size bound.
    ///   - now: the instant to evaluate the grant against.
    func authorize(_ request: HTTPRequest, body: Data, now: Date) async -> AuthorizeOutcome?
}

/// The outcome a ``RequestAuthorizer`` returns for a credential-less request.
public enum AuthorizeOutcome: Sendable {
    /// The request is authorized: run the protected handler, attaching `receipt` as the
    /// `Payment-Receipt` (a renewal charge, or `nil` when the grant settled nothing this request).
    case authorized(Receipt?)
    /// A terminal response to return as-is, without running the handler (for example `409` with
    /// `Retry-After` while another renewer holds the period, or `503` on a transient charge
    /// failure).
    case respond(HTTPResponse, Data)
}

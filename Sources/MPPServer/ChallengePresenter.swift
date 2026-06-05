import Foundation
import HTTPTypes
import MPPCore

/// An alternative representation of a `402` challenge body: a content type and
/// the bytes to send. The middleware always sets the `402` status, the
/// `WWW-Authenticate` challenge, and `Cache-Control: no-store`; a presenter
/// supplies only this representation, so the protocol-required headers can never
/// be forgotten.
public struct PresentedChallenge: Sendable {
    /// The `Content-Type` for the body (e.g. `text/html; charset=utf-8`).
    public let contentType: String
    /// The response body.
    public let body: Data

    public init(contentType: String, body: Data) {
        self.contentType = contentType
        self.body = body
    }
}

/// An optional seam for rendering a `402` challenge in a representation other
/// than the default `application/problem+json` -- for example a server-rendered
/// HTML payment page when the client sends `Accept: text/html`.
///
/// Consulted only on the retryable `402` challenge path (a credential-less
/// request or a `402` rejection), never on a terminal §10.5 settlement problem,
/// which offers no retry. Returning `nil` keeps the default problem document.
/// Defined here, not in the HTML module, so `MPPServer` carries no dependency on
/// any particular renderer; a host wires a concrete presenter (e.g. the one in
/// `MPPHTMLServer`) into ``MPPServerMiddleware``.
public protocol ChallengePresenter: Sendable {
    /// Optionally renders the challenge body. `request` carries the negotiation
    /// inputs (e.g. the `Accept` header); `challenges` is every offered method's
    /// challenge (one per `WWW-Authenticate` header, the first being the primary)
    /// and `problem` is the same value the default response would carry. Return
    /// `nil` to use the default.
    func present(
        _ request: HTTPRequest,
        challenges: [Challenge],
        problem: ProblemDetails
    ) async -> PresentedChallenge?
}

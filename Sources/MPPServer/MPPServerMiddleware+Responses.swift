import Foundation
import HTTPTypes
import MPPCore

// HTTP response construction for `MPPServerMiddleware`, factored out of the main file to stay under
// the length limits. These are internal `static` helpers (called as `Self.…` from
// `handle`/`serve`).
extension MPPServerMiddleware {
    static let problemContentType = "application/problem+json"

    /// The `Payment-Receipt` response header name (non-standard, so built from a
    /// compile-time-known-valid token).
    static let paymentReceiptField: HTTPField.Name = {
        guard let name = HTTPField.Name("Payment-Receipt") else {
            preconditionFailure("Payment-Receipt is a valid HTTP field name")
        }
        return name
    }()

    /// A `402` offering `challenge` in `WWW-Authenticate` (the retry challenge), with the problem
    /// body. Only the retryable `402` path reaches here; a terminal settlement problem uses
    /// ``problemResponse(_:)``.
    static func paymentRequiredResponse(
        challenge: Challenge, problem: ProblemDetails
    ) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 402))
        response.headerFields[.wwwAuthenticate] = challenge.headerValue
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = problemContentType
        return (response, encodedProblem(problem))
    }

    /// A terminal settlement problem (§10.5): the problem's own status (e.g. `410` / `400`) and
    /// body, with no `WWW-Authenticate` (no retry challenge is offered), matching the mppx peer,
    /// which associates the challenge with `402` responses alone.
    static func problemResponse(_ problem: ProblemDetails) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: problem.status ?? 402))
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = problemContentType
        return (response, encodedProblem(problem))
    }

    static func payloadTooLargeResponse(maxBodyBytes: Int) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 413))
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = problemContentType
        // No `type`: an absent type is `about:blank` (RFC 9457 §3.1.1). The 413 is
        // a transport-level guard, not a payment problem.
        let problem = ProblemDetails(
            title: "Payload Too Large",
            status: 413,
            detail: "The request body exceeded the \(maxBodyBytes)-byte limit."
        )
        return (response, encodedProblem(problem))
    }

    static func tooManyRequestsResponse(retryAfter: TimeInterval) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 429))
        // Retry-After is whole seconds (RFC 9110 §10.2.3), rounded up to at least 1 so a client
        // never retries before a token is actually available.
        let seconds = max(1, Int(retryAfter.rounded(.up)))
        response.headerFields[.retryAfter] = String(seconds)
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = problemContentType
        // No `type` (about:blank, like the 413): the 429 is a transport-level DoS guard, not a
        // payment problem.
        let problem = ProblemDetails(
            title: "Too Many Requests",
            status: 429,
            detail: "Rate limit exceeded; retry after \(seconds) second(s)."
        )
        return (response, encodedProblem(problem))
    }

    static func encodedProblem(_ problem: ProblemDetails) -> Data {
        // Canonical encoding, matching `Credential.headerValue`: sorted keys so the
        // body is deterministic regardless of extension-member count, and unescaped
        // slashes so the problem `type` URIs read cleanly on the wire. The body is
        // best-effort (it cannot realistically fail); the status and headers, which
        // the protocol decision depends on, are always authoritative.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(problem)) ?? Data()
    }
}

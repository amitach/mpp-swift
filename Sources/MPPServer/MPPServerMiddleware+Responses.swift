import Foundation
import HTTPTypes
import MPPCore

// HTTP response construction for `MPPServerMiddleware`, factored out of the main file to stay under
// the length limits. These are internal `static` helpers (called as `Self.…` from
// `handle`/`serve`).
extension MPPServerMiddleware {
    /// Runs the protected handler for an authorized request, enforcing the §11.10 `Cache-Control:
    /// private` floor and attaching the `Payment-Receipt` when the token carries one. Shared by the
    /// verified-credential path and the credential-less authorize path.
    ///
    /// Internal (not `private`) only so `handleCore` in the main file can reach it across the
    /// file split; it is not a public or guarded entry point. Reaching it still requires an
    /// `MPPVerified`, which only this module can mint (via the verifier or authorizer), so the
    /// transport guards (rate limit, idempotency, body cap) and payment verification are not
    /// bypassable in practice. Do not call it directly; the guarded entry point is
    /// ``handle(_:body:now:handler:)``.
    func serve(
        _ request: HTTPRequest,
        verified: MPPVerified,
        handler: (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data)
    ) async -> (HTTPResponse, Data) {
        var (response, responseBody) = await handler(request, verified)
        // §11.10 floor: a paid response must be at least `private`. Keep a directive that already
        // meets it (the stricter `no-store`, or an explicit `private`); otherwise enforce
        // `private`,
        // covering an absent value, a `public`, or a bare `max-age` a handler may have set.
        let cacheControl = response.headerFields[.cacheControl]
        let meetsFloor = cacheControl.map { $0.contains("no-store") || $0.contains("private") }
        if meetsFloor != true {
            response.headerFields[.cacheControl] = "private"
        }
        // Attach the settlement receipt (Payment-Receipt), when one was minted. The header is
        // optional (spec: for auditability), so an encoding failure on an otherwise-valid receipt
        // is
        // swallowed rather than failing the response the client already earned.
        if let receipt = verified.receipt, let value = try? receipt.headerValue {
            response.headerFields[Self.paymentReceiptField] = value
        }
        return (response, responseBody)
    }

    static let problemContentType = "application/problem+json"

    /// The `Payment-Receipt` response header name (non-standard, so built from a
    /// compile-time-known-valid token). The name is the canonical
    /// ``MPPSensitiveSurfaces/receiptHeader`` so the redaction registry cannot drift from it.
    static let paymentReceiptField: HTTPField.Name = {
        guard let name = HTTPField.Name(MPPSensitiveSurfaces.receiptHeader) else {
            preconditionFailure("Payment-Receipt is a valid HTTP field name")
        }
        return name
    }()

    /// A `402` offering each `challenges` element in its own `WWW-Authenticate` header (RFC 9110
    /// §11.6.1: a client may be offered several challenges at once), with the problem body. Only
    /// the
    /// retryable `402` path reaches here; a terminal settlement problem uses
    /// ``problemResponse(_:)``.
    static func paymentRequiredResponse(
        challenges: [Challenge], problem: ProblemDetails
    ) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 402))
        offerChallenges(challenges, on: &response)
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = problemContentType
        return (response, encodedProblem(problem))
    }

    /// A `402` carrying a ``ChallengePresenter``'s alternative representation (e.g. an HTML page):
    /// the same per-offer `WWW-Authenticate` challenges and `no-store` floor as the default, with
    /// the presenter's content type and body in place of the problem document.
    static func paymentRequiredResponse(
        challenges: [Challenge], presented: PresentedChallenge
    ) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 402))
        offerChallenges(challenges, on: &response)
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = presented.contentType
        return (response, presented.body)
    }

    /// Appends one `WWW-Authenticate: Payment …` header per challenge (a separate header line each,
    /// the shape the client parses via `headerFields[values: .wwwAuthenticate]`).
    private static func offerChallenges(
        _ challenges: [Challenge],
        on response: inout HTTPResponse
    ) {
        for challenge in challenges {
            response.headerFields.append(HTTPField(
                name: .wwwAuthenticate,
                value: challenge.headerValue
            ))
        }
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

    /// The `Idempotency-Key` request header name (non-standard, so built from a
    /// compile-time-known-valid token).
    static let idempotencyKeyField: HTTPField.Name = {
        guard let name = HTTPField.Name("Idempotency-Key") else {
            preconditionFailure("Idempotency-Key is a valid HTTP field name")
        }
        return name
    }()

    /// The `Accept-Payment` request header name (§6, non-standard, so built from a
    /// compile-time-known-valid token).
    static let acceptPaymentField: HTTPField.Name = {
        guard let name = HTTPField.Name("Accept-Payment") else {
            preconditionFailure("Accept-Payment is a valid HTTP field name")
        }
        return name
    }()

    /// A `409` for an `Idempotency-Key` whose request is still in flight (§11.4): the client must
    /// not retry concurrently; it retries once the original completes (and then replays).
    static func conflictResponse() -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 409))
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = problemContentType
        let problem = ProblemDetails(
            title: "Conflict",
            status: 409,
            detail: "A request with this Idempotency-Key is already in progress."
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

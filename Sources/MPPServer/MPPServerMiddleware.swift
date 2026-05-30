import Foundation
import HTTPTypes
import MPPCore

/// Ties mint and verify into the server side of one payment-protected route.
///
/// On each request the middleware: rejects an over-large body with `413` before
/// any payment work; mints a fresh `402` challenge when no credential is present;
/// otherwise verifies the credential (``PaymentVerifier``) and, on success, runs
/// the protected handler. The handler is typed `(HTTPRequest, MPPVerified) ->
/// (HTTPResponse, Data)`, so it structurally cannot run on an unpaid request:
/// only a verified credential yields the ``MPPVerified`` token it requires.
///
/// The protocol logic lives in the pure, HTTP-free ``evaluate(authorization:body:now:)``
/// so it is testable on values; ``handle(_:body:now:handler:)`` is the thin
/// binding over `apple/swift-http-types` currency types (`HTTPRequest` /
/// `HTTPResponse`), the framework-neutral representation that server frameworks
/// (Hummingbird, Vapor) interoperate with.
///
/// The receipt is minted by the layers below, not here: a payment method reports
/// the settlement `reference` and ``PaymentVerifier`` mints the ``Receipt`` (the
/// method layer owns settlement). When verification produced one (``MPPVerified``
/// carries it), this layer attaches it as the optional `Payment-Receipt` response
/// header (`draft-httpauth-payment-00` §5.3); in protocol-only mode there is no
/// receipt to attach. The middleware also sets `Cache-Control: private` on the
/// paid response and `no-store` on every `402` / `413` (§11.10).
public struct MPPServerMiddleware: Sendable {
    private let minter: ChallengeMinter
    private let verifier: PaymentVerifier
    private let binding: RouteBinding
    private let challengeRequest: EncodedJSON
    private let expiresIn: TimeInterval?
    private let maxBodyBytes: Int
    private let onEvent: @Sendable (ServerEvent) -> Void

    /// Creates a middleware for one route.
    ///
    /// - Parameters:
    ///   - minter: Mints the route's challenges.
    ///   - verifier: Verifies presented credentials (same server secret as `minter`).
    ///   - binding: The route's `(realm, method, intent)`. Used to both mint the
    ///     offered challenge and pin verification, so the two cannot drift.
    ///   - request: The method-specific request to advertise, `base64url(JCS(json))`.
    ///   - expiresIn: Challenge lifetime from mint time, in seconds; `nil` mints a
    ///     challenge with no expiry. Pass a non-negative value: a negative interval
    ///     would mint already-expired challenges, making the route inaccessible.
    ///   - maxBodyBytes: Request bodies larger than this are rejected with `413`
    ///     before any payment work. Defaults to 10 MiB. This bound is an MPP-swift
    ///     denial-of-service guard (the spec does not mandate it), so the digest
    ///     buffer is bounded before it is hashed. Pass a positive value: `0` rejects
    ///     every non-empty body and a negative value rejects even an empty one.
    ///   - onEvent: A synchronous diagnostics sink; defaults to a no-op.
    ///
    /// A digest-bound, described, or opaque-carrying challenge is minted via
    /// ``ChallengeMinter`` directly; the middleware advertises only the route's
    /// request and expiry until a consumer needs those other slots.
    public init(
        minter: ChallengeMinter,
        verifier: PaymentVerifier,
        binding: RouteBinding,
        request: EncodedJSON,
        expiresIn: TimeInterval? = nil,
        maxBodyBytes: Int = 10 * 1024 * 1024,
        onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
    ) {
        self.minter = minter
        self.verifier = verifier
        self.binding = binding
        challengeRequest = request
        self.expiresIn = expiresIn
        self.maxBodyBytes = maxBodyBytes
        self.onEvent = onEvent
    }

    /// The HTTP-free outcome of evaluating a request.
    public enum Decision: Sendable {
        /// The body exceeded `maxBodyBytes`; answer `413` before any payment work.
        case payloadTooLarge
        /// No valid credential; answer `402` with this challenge and problem body.
        case challenge(Challenge, ProblemDetails)
        /// The credential verified; run the protected handler with this token.
        case proceed(MPPVerified)
    }

    /// Evaluates a request's payment state, free of any HTTP type.
    ///
    /// - Parameters:
    ///   - authorization: The `Authorization` header value, or `nil` if absent.
    ///   - body: The full request body (its size is checked against `maxBodyBytes`).
    ///   - now: The instant to evaluate expiry against.
    /// - Returns: the ``Decision`` for the request. Emits a ``ServerEvent`` for the
    ///   minted-challenge, verified, and rejected branches.
    public func evaluate(authorization: String?, body: Data, now: Date) async -> Decision {
        // Bound the body before any payment work, so an oversized request never
        // reaches credential parsing or digest hashing.
        if body.count > maxBodyBytes {
            return .payloadTooLarge
        }

        guard let authorization else {
            let challenge = mintChallenge(now: now)
            onEvent(.challengeIssued(challenge))
            let problem = Self.problem(for: .freshChallenge, challengeID: challenge.id)
            return .challenge(challenge, problem)
        }

        let outcome = await verifier.verify(
            authorization: authorization, body: body, now: now, expecting: binding
        )
        switch outcome {
        case let .verified(verified):
            onEvent(.paymentVerified(verified))
            return .proceed(verified)
        case let .rejected(rejection):
            // Offer a fresh challenge alongside the rejection so the client can retry.
            // Both moments are reported: the rejection, then the retry challenge that
            // was issued (so `challengeIssued` counts every minted challenge).
            let challenge = mintChallenge(now: now)
            onEvent(.paymentRejected(rejection))
            onEvent(.challengeIssued(challenge))
            let problem = Self.problem(for: .rejection(rejection), challengeID: challenge.id)
            return .challenge(challenge, problem)
        }
    }

    /// Runs the route over `apple/swift-http-types` values: reads the credential
    /// and body, evaluates, and either answers `402`/`413` or runs `handler` and
    /// enforces the `Cache-Control: private` floor on its response (§11.10): a
    /// stricter directive the handler chose (`no-store`, or an explicit `private`)
    /// is kept; anything weaker or absent becomes `private`.
    public func handle(
        _ request: HTTPRequest,
        body: Data,
        now: Date,
        handler: (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data)
    ) async -> (HTTPResponse, Data) {
        let authorization = request.headerFields[.authorization]
        switch await evaluate(authorization: authorization, body: body, now: now) {
        case .payloadTooLarge:
            return Self.payloadTooLargeResponse(maxBodyBytes: maxBodyBytes)
        case let .challenge(challenge, problem):
            return Self.paymentRequiredResponse(challenge: challenge, problem: problem)
        case let .proceed(verified):
            var (response, responseBody) = await handler(request, verified)
            // §11.10 floor: a paid response must be at least `private`. Keep a
            // directive that already meets it (the stricter `no-store`, or an
            // explicit `private`); otherwise enforce `private`, covering an absent
            // value, a `public`, or a bare `max-age` a handler may have set.
            let cacheControl = response.headerFields[.cacheControl]
            let meetsFloor = cacheControl.map { $0.contains("no-store") || $0.contains("private") }
            if meetsFloor != true {
                response.headerFields[.cacheControl] = "private"
            }
            // Attach the settlement receipt (Payment-Receipt), when a method minted
            // one. The header is optional (spec: for auditability), so an encoding
            // failure on an otherwise-valid receipt is swallowed rather than failing
            // the paid response the client already earned.
            if let receipt = verified.receipt, let value = try? receipt.headerValue {
                response.headerFields[Self.paymentReceiptField] = value
            }
            return (response, responseBody)
        }
    }

    private func mintChallenge(now: Date) -> Challenge {
        minter.mint(
            binding: binding,
            request: challengeRequest,
            expires: expiresIn.map { Expires(date: now.addingTimeInterval($0)) }
        )
    }

    // MARK: - Problem details

    private enum ProblemCause {
        case freshChallenge
        case rejection(PaymentVerifier.Rejection)
    }

    /// Builds the RFC 9457 problem for a 402, using the paymentauth.org problem
    /// type registry and carrying the offered challenge id as a `challengeId`
    /// extension member.
    /// The slug/title/detail for a 402 problem.
    private struct Spec { let slug: String; let title: String; let detail: String }

    private static func problem(for cause: ProblemCause, challengeID: String) -> ProblemDetails {
        let spec = Self.spec(for: cause)
        return ProblemDetails(
            type: "https://paymentauth.org/problems/\(spec.slug)",
            title: spec.title,
            status: 402,
            detail: spec.detail,
            extensions: ["challengeId": .string(challengeID)]
        )
    }

    private static func verificationFailed(_ detail: String) -> Spec {
        Spec(slug: "verification-failed", title: "Verification Failed", detail: detail)
    }

    private static func invalidChallenge(_ detail: String) -> Spec {
        Spec(slug: "invalid-challenge", title: "Invalid Challenge", detail: detail)
    }

    /// The problem for a 402 cause. `settlementUnverified`'s `reason` is deliberately
    /// not echoed to the client. An already-used id maps to `invalid-challenge` per
    /// spec (§8.2 / §4.2: "unknown, expired, or already used"), not a proof failure.
    private static func spec(for cause: ProblemCause) -> Spec {
        switch cause {
        case .freshChallenge:
            Spec(
                slug: "payment-required",
                title: "Payment Required",
                detail: "This resource requires payment."
            )
        case .rejection(.malformedCredential):
            Spec(
                slug: "malformed-credential",
                title: "Malformed Credential",
                detail: "The Authorization header was not a parseable Payment credential."
            )
        case .rejection(.expired):
            Spec(
                slug: "payment-expired",
                title: "Payment Expired",
                detail: "The challenge had expired."
            )
        case .rejection(.invalidChallenge):
            invalidChallenge("The credential's challenge was not issued by this server.")
        case .rejection(.replayed):
            invalidChallenge("The challenge has already been used.")
        case .rejection(.bindingMismatch):
            verificationFailed("The credential's challenge does not match this resource.")
        case .rejection(.digestMismatch):
            verificationFailed("The request body did not match the challenge digest.")
        case .rejection(.settlementUnverified):
            verificationFailed("The payment could not be verified on its rail.")
        case .rejection(.noSupportingMethod):
            verificationFailed("No payment method can settle this challenge.")
        }
    }

    // MARK: - Response building

    private static let problemContentType = "application/problem+json"

    /// The `Payment-Receipt` response header name (non-standard, so built from a
    /// compile-time-known-valid token).
    private static let paymentReceiptField: HTTPField.Name = {
        guard let name = HTTPField.Name("Payment-Receipt") else {
            preconditionFailure("Payment-Receipt is a valid HTTP field name")
        }
        return name
    }()

    private static func paymentRequiredResponse(
        challenge: Challenge, problem: ProblemDetails
    ) -> (HTTPResponse, Data) {
        var response = HTTPResponse(status: .init(code: 402))
        response.headerFields[.wwwAuthenticate] = challenge.headerValue
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentType] = problemContentType
        return (response, encodedProblem(problem))
    }

    private static func payloadTooLargeResponse(maxBodyBytes: Int) -> (HTTPResponse, Data) {
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

    private static func encodedProblem(_ problem: ProblemDetails) -> Data {
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

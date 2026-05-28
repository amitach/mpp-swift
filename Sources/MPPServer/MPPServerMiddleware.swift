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
/// This layer attests protocol-level validity only and does **not** mint a
/// `Payment-Receipt`: a receipt carries a settlement `reference` that exists
/// only once a payment method has settled (`draft-httpauth-payment-00` §5.3),
/// which is the method layer's job. The middleware sets `Cache-Control: private`
/// on the paid response and `no-store` on every `402` / `413` (§11.10).
public struct MPPServerMiddleware: Sendable {
    private let minter: ChallengeMinter
    private let verifier: PaymentVerifier
    private let binding: RouteBinding
    private let challengeRequest: EncodedJSON
    private let expiresIn: TimeInterval?
    private let challengeDigest: String?
    private let challengeDescription: String?
    private let challengeOpaque: EncodedJSON?
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
    ///     challenge with no expiry.
    ///   - digest: Optional RFC 9530 digest of the expected request body to bind.
    ///   - description: Optional display-only text for the challenge.
    ///   - opaque: Optional server correlation data, `base64url(JCS(json))`.
    ///   - maxBodyBytes: Request bodies larger than this are rejected with `413`
    ///     before any payment work. Defaults to 10 MiB. This bound is an MPP-swift
    ///     denial-of-service guard (the spec does not mandate it), so the digest
    ///     buffer is bounded before it is hashed.
    ///   - onEvent: A synchronous diagnostics sink; defaults to a no-op.
    public init(
        minter: ChallengeMinter,
        verifier: PaymentVerifier,
        binding: RouteBinding,
        request: EncodedJSON,
        expiresIn: TimeInterval? = nil,
        digest: String? = nil,
        description: String? = nil,
        opaque: EncodedJSON? = nil,
        maxBodyBytes: Int = 10 * 1024 * 1024,
        onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
    ) {
        self.minter = minter
        self.verifier = verifier
        self.binding = binding
        self.challengeRequest = request
        self.expiresIn = expiresIn
        self.challengeDigest = digest
        self.challengeDescription = description
        self.challengeOpaque = opaque
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
        case .verified(let verified):
            onEvent(.paymentVerified(verified))
            return .proceed(verified)
        case .rejected(let rejection):
            // Offer a fresh challenge alongside the rejection so the client can retry.
            let challenge = mintChallenge(now: now)
            onEvent(.paymentRejected(rejection))
            let problem = Self.problem(for: .rejection(rejection), challengeID: challenge.id)
            return .challenge(challenge, problem)
        }
    }

    /// Runs the route over `apple/swift-http-types` values: reads the credential
    /// and body, evaluates, and either answers `402`/`413` or runs `handler` and
    /// decorates its response with `Cache-Control: private`.
    public func handle(
        _ request: HTTPRequest,
        body: Data,
        now: Date,
        handler: (HTTPRequest, MPPVerified) -> (HTTPResponse, Data)
    ) async -> (HTTPResponse, Data) {
        let authorization = request.headerFields[.authorization]
        switch await evaluate(authorization: authorization, body: body, now: now) {
        case .payloadTooLarge:
            return Self.payloadTooLargeResponse(maxBodyBytes: maxBodyBytes)
        case .challenge(let challenge, let problem):
            return Self.paymentRequiredResponse(challenge: challenge, problem: problem)
        case .proceed(let verified):
            var (response, responseBody) = handler(request, verified)
            response.headerFields[.cacheControl] = "private"
            return (response, responseBody)
        }
    }

    private func mintChallenge(now: Date) -> Challenge {
        minter.mint(
            binding: binding,
            request: challengeRequest,
            digest: challengeDigest,
            expires: expiresIn.map { Expires(date: now.addingTimeInterval($0)) },
            description: challengeDescription,
            opaque: challengeOpaque
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
    private static func problem(for cause: ProblemCause, challengeID: String) -> ProblemDetails {
        func make(_ slug: String, _ title: String, _ detail: String) -> ProblemDetails {
            ProblemDetails(
                type: "https://paymentauth.org/problems/\(slug)",
                title: title,
                status: 402,
                detail: detail,
                extensions: ["challengeId": .string(challengeID)]
            )
        }
        switch cause {
        case .freshChallenge:
            return make("payment-required", "Payment Required", "This resource requires payment.")
        case .rejection(.malformedCredential):
            return make("malformed-credential", "Malformed Credential",
                        "The Authorization header was not a parseable Payment credential.")
        case .rejection(.invalidChallenge):
            return make("invalid-challenge", "Invalid Challenge",
                        "The credential's challenge was not issued by this server.")
        case .rejection(.bindingMismatch):
            return make("verification-failed", "Verification Failed",
                        "The credential's challenge does not match this resource.")
        case .rejection(.expired):
            return make("payment-expired", "Payment Expired", "The challenge had expired.")
        case .rejection(.digestMismatch):
            return make("verification-failed", "Verification Failed",
                        "The request body did not match the challenge digest.")
        case .rejection(.replayed):
            return make("verification-failed", "Verification Failed",
                        "The challenge has already been used.")
        }
    }

    // MARK: - Response building

    private static let problemContentType = "application/problem+json"

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
        // A ProblemDetails encodes deterministically and cannot realistically
        // fail; the body is best-effort, while the status and headers (which the
        // protocol decision depends on) are always authoritative.
        (try? JSONEncoder().encode(problem)) ?? Data()
    }
}

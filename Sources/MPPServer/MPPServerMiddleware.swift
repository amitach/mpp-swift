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
/// The receipt is minted by the layers below, not here: a payment method mints its
/// own ``Receipt`` and ``PaymentVerifier`` carries it (the method layer owns
/// settlement). When verification produced one (``MPPVerified`` carries it), this
/// layer attaches it as the optional `Payment-Receipt` response header
/// (`draft-httpauth-payment-00` §5.3); in protocol-only mode there is no receipt to
/// attach. The middleware also sets `Cache-Control: private` on the paid response
/// and `no-store` on every `402` / `413` (§11.10).
public struct MPPServerMiddleware: Sendable {
    private let minter: ChallengeMinter
    private let verifier: PaymentVerifier
    private let binding: RouteBinding
    private let challengeRequest: EncodedJSON
    private let expiresIn: TimeInterval?
    private let maxBodyBytes: Int
    private let authorizer: (any RequestAuthorizer)?
    private let rateLimiter: (any RateLimiter)?
    private let rateLimitKey: @Sendable (HTTPRequest) -> String?
    private let idempotencyStore: (any IdempotencyStore)?
    private let onEvent: @Sendable (ServerEvent) -> Void

    /// Creates a middleware for one route.
    ///
    /// - Parameters:
    ///   - minter: Mints the route's challenges.
    ///   - verifier: Verifies presented credentials (same server secret as `minter`).
    ///   - binding: The route's `(realm, method, intent)`. Used to both mint the
    ///     offered challenge and pin verification, so the two cannot drift.
    ///   - request: The method-specific request to advertise, `base64url(JCS(json))`.
    ///   - expiresIn: Challenge lifetime from mint time, in seconds; defaults to 300
    ///     (5 minutes, matching the mppx reference peer). Pass a non-negative value: a
    ///     negative interval would mint already-expired challenges, making the route
    ///     inaccessible. `nil` mints a non-lapsing challenge, which this server's own
    ///     ``PaymentVerifier`` rejects (it requires an expiry; see DIVERGING_FROM_SPEC
    ///     there), so pass `nil` only when pairing with a verifier that accepts
    ///     no-expiry challenges.
    ///   - maxBodyBytes: Request bodies larger than this are rejected with `413`
    ///     before any payment work. Defaults to 10 MiB. This bound is an MPP-swift
    ///     denial-of-service guard (the spec does not mandate it), so the digest
    ///     buffer is bounded before it is hashed. Pass a positive value: `0` rejects
    ///     every non-empty body and a negative value rejects even an empty one.
    ///   - authorizer: An optional ``RequestAuthorizer`` consulted on credential-less
    ///     requests before minting a `402` (for example a returning subscriber). Defaults
    ///     to `nil`, in which case every credential-less request gets a `402`.
    ///   - rateLimiter: An optional ``RateLimiter`` consulted at the top of
    ///     ``handle(_:body:now:handler:)``, before any payment work, to throttle a flood
    ///     (§11.12). Defaults to `nil` (no limiting). Only used by `handle`; the pure
    ///     ``evaluate(authorization:body:now:)`` has no request to key on.
    ///   - rateLimitKey: Derives the client key the ``RateLimiter`` is keyed on from the
    ///     request (for example `request.headerFields[.init("X-Forwarded-For")!]`). Defaults
    ///     to returning `nil` (no key, so no limiting) since the transport remote address is
    ///     not in `HTTPRequest`; the host wires its own extractor.
    ///   - idempotencyStore: An optional ``IdempotencyStore``. When set and the request carries an
    ///     `Idempotency-Key` header (§11.4), `handle` replays the recorded response for a repeated
    ///     key (no re-charge), answers `409` while one is in flight, and records only a settled
    ///     response. Defaults to `nil` (no idempotency). Only used by `handle`.
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
        expiresIn: TimeInterval? = 300,
        maxBodyBytes: Int = 10 * 1024 * 1024,
        authorizer: (any RequestAuthorizer)? = nil,
        rateLimiter: (any RateLimiter)? = nil,
        rateLimitKey: @escaping @Sendable (HTTPRequest) -> String? = { _ in nil },
        idempotencyStore: (any IdempotencyStore)? = nil,
        onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
    ) {
        self.minter = minter
        self.verifier = verifier
        self.binding = binding
        challengeRequest = request
        self.expiresIn = expiresIn
        self.maxBodyBytes = maxBodyBytes
        self.authorizer = authorizer
        self.rateLimiter = rateLimiter
        self.idempotencyStore = idempotencyStore
        self.rateLimitKey = rateLimitKey
        self.onEvent = onEvent
    }

    /// Wires the standard single-route gate: a `secret`-keyed ``ChallengeSigner``
    /// feeding a ``ChallengeMinter`` and a ``PaymentVerifier``, bound to `binding`'s
    /// route. The common-case shortcut for the signer → minter/verifier wiring every
    /// gated route repeats; `replayStore` defaults to an in-memory store (override
    /// for a persistent one), and the full initializer remains for control over
    /// expiry, body limits, or an authorizer.
    public static func make(
        secret: Data,
        binding: RouteBinding,
        request: EncodedJSON,
        methods: [any PaymentMethodServer],
        replayStore: any ReplayStore = InMemoryReplayStore(),
        onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
    ) -> MPPServerMiddleware {
        let signer = ChallengeSigner(secret: secret)
        return MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            verifier: PaymentVerifier(signer: signer, replayStore: replayStore, methods: methods),
            binding: binding,
            request: request,
            onEvent: onEvent
        )
    }

    /// The HTTP-free outcome of evaluating a request.
    public enum Decision: Sendable {
        /// The body exceeded `maxBodyBytes`; answer `413` before any payment work.
        case payloadTooLarge
        /// No valid (or a retryable-`402`) credential; answer `402` with this retry challenge
        /// (offered in `WWW-Authenticate`) and problem body.
        case challenge(Challenge, ProblemDetails)
        /// A terminal settlement problem (§10.5): answer with the problem's own status (e.g. `410`
        /// for a closed/unknown channel, `400` for a malformed request) and body, offering no
        /// retry challenge. Distinct from ``challenge(_:_:)`` precisely so no challenge is minted,
        /// counted, or embedded for a response the client cannot retry on the same terms.
        case problem(ProblemDetails)
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
            onEvent(.paymentRejected(rejection))
            // A 402 rejection offers a fresh retry challenge (and counts it as issued), so the
            // client can present a corrected credential. A terminal 410/400 settlement problem
            // (§10.5) offers none: it mints no challenge, fires no `challengeIssued`, and embeds
            // no `challengeId` (the client cannot retry on a challenge it was never given).
            if Self.problemStatus(for: rejection) == 402 {
                let challenge = mintChallenge(now: now)
                onEvent(.challengeIssued(challenge))
                let problem = Self.problem(for: .rejection(rejection), challengeID: challenge.id)
                return .challenge(challenge, problem)
            }
            return .problem(Self.problem(for: .rejection(rejection), challengeID: nil))
        }
    }

    /// Runs the route over `apple/swift-http-types` values. Two optional transport guards run first
    /// when configured: a rate limit (§11.12, `429`) and idempotent retry (§11.4, replay a settled
    /// response or `409` while one is in flight). The core then reads the credential and body,
    /// evaluates, and either answers `402`/`413` or runs `handler` and enforces the `Cache-Control:
    /// private` floor on its response (§11.10): a stricter directive the handler chose (`no-store`,
    /// or an explicit `private`) is kept; anything weaker or absent becomes `private`.
    public func handle(
        _ request: HTTPRequest,
        body: Data,
        now: Date,
        handler: (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data)
    ) async -> (HTTPResponse, Data) {
        // Throttle first (§11.12): a flood is rejected with `429` before the body cap, the
        // authorize seam, or any payment work, so a limited client costs the least. Only the
        // `handle` path rate-limits, because the key is derived from the request.
        if let rateLimiter, let key = rateLimitKey(request),
           case let .limited(retryAfter) = await rateLimiter.reserve(key, now: now) {
            onEvent(.rateLimited(key: key))
            return Self.tooManyRequestsResponse(retryAfter: retryAfter)
        }
        // Idempotent retry (§11.4): with a store and an `Idempotency-Key`, replay a settled
        // response for a repeated key (no re-charge), answer `409` while one is in flight, and
        // record only a settled (handler-run) response so an unsettled attempt can still pay later.
        guard let idempotencyStore, let key = request.headerFields[Self.idempotencyKeyField] else {
            let out = await handleCore(request, body: body, now: now, handler: handler)
            return (out.response, out.body)
        }
        switch await idempotencyStore.begin(key) {
        case let .replay(recorded):
            return (recorded.response, recorded.body)
        case .inProgress:
            return Self.conflictResponse()
        case .proceed:
            let out = await handleCore(request, body: body, now: now, handler: handler)
            if out.served {
                let recorded = IdempotentResponse(response: out.response, body: out.body)
                await idempotencyStore.complete(key, response: recorded)
            } else {
                await idempotencyStore.release(key)
            }
            return (out.response, out.body)
        }
    }

    /// The body-cap + authorize + evaluate pipeline, reporting whether the protected handler ran
    /// (`served`) so the idempotency wrapper records only a settled response.
    private func handleCore(
        _ request: HTTPRequest,
        body: Data,
        now: Date,
        handler: (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data)
    ) async -> CoreResult {
        func served(_ pair: (HTTPResponse, Data)) -> CoreResult {
            CoreResult(pair, served: true)
        }
        func guarded(_ pair: (HTTPResponse, Data)) -> CoreResult {
            CoreResult(pair, served: false)
        }

        // Bound the body before any payment or authorize work. `evaluate` enforces the same cap for
        // its own callers; the authorize path below bypasses `evaluate`, so it is checked here too.
        if body.count > maxBodyBytes {
            return guarded(Self.payloadTooLargeResponse(maxBodyBytes: maxBodyBytes))
        }
        let authorization = request.headerFields[.authorization]
        // A credential-less request: consult an operator-configured authorizer (for example a
        // returning subscriber recognized without a credential) before minting a 402.
        if authorization == nil, let authorizer {
            switch await authorizer.authorize(request, body: body, now: now) {
            case let .authorized(receipt):
                // Report the authorize path through onEvent too, so an operator's paymentVerified
                // counts include credential-less returning subscribers.
                let verified = MPPVerified(credential: nil, receipt: receipt)
                onEvent(.paymentVerified(verified))
                return await served(serve(request, verified: verified, handler: handler))
            case let .respond(response, responseBody):
                return guarded((response, responseBody))
            case .none:
                break // fall through to mint a 402
            }
        }
        switch await evaluate(authorization: authorization, body: body, now: now) {
        case .payloadTooLarge:
            return guarded(Self.payloadTooLargeResponse(maxBodyBytes: maxBodyBytes))
        case let .challenge(challenge, problem):
            return guarded(Self.paymentRequiredResponse(challenge: challenge, problem: problem))
        case let .problem(problem):
            return guarded(Self.problemResponse(problem))
        case let .proceed(verified):
            return await served(serve(request, verified: verified, handler: handler))
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

    /// The HTTP status a rejection answers with (402 by default; a §10.5 settlement problem may be
    /// 410 / 400). Drives whether a retry challenge is offered.
    private static func problemStatus(for rejection: PaymentVerifier.Rejection) -> Int {
        spec(for: .rejection(rejection)).status
    }

    /// Builds the RFC 9457 problem for a cause, using the paymentauth.org problem type registry.
    /// When `challengeID` is non-nil it is carried as the `challengeId` extension member (the
    /// offered retry challenge); a terminal settlement problem passes `nil` to omit it. Most causes
    /// are `402`; a §10.5 settlement problem carries its own status (e.g. `410` / `400`).
    private struct Spec {
        let slug: String
        let title: String
        let detail: String
        var status: Int = 402
    }

    private static func problem(for cause: ProblemCause, challengeID: String?) -> ProblemDetails {
        let spec = Self.spec(for: cause)
        return ProblemDetails(
            type: "https://paymentauth.org/problems/\(spec.slug)",
            title: spec.title,
            status: spec.status,
            detail: spec.detail,
            extensions: challengeID.map { ["challengeId": .string($0)] } ?? [:]
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
        case let .rejection(.settlement(problem)):
            // §10.5: the method supplied a typed problem (its own type, title, and status).
            Spec(
                slug: problem.slug, title: problem.title, detail: problem.detail,
                status: problem.status
            )
        }
    }
}

/// The result of `MPPServerMiddleware.handleCore`: the response plus whether the protected handler
/// ran (`served`), so the idempotency wrapper records only a settled response. File-scope so it
/// does not count against the method's body length.
private struct CoreResult {
    let response: HTTPResponse
    let body: Data
    let served: Bool

    init(_ pair: (HTTPResponse, Data), served: Bool) {
        response = pair.0
        body = pair.1
        self.served = served
    }
}

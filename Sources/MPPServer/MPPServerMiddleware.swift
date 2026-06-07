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
    private let offers: [MethodOffer]
    private let expiresIn: TimeInterval?
    private let maxBodyBytes: Int
    private let authorizer: (any RequestAuthorizer)?
    private let rateLimiter: (any RateLimiter)?
    private let rateLimitKey: @Sendable (HTTPRequest) -> String?
    private let idempotencyStore: (any IdempotencyStore)?
    private let presenter: (any ChallengePresenter)?
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
    ///   - presenter: An optional ``ChallengePresenter`` consulted on the `402` challenge path to
    ///     render the body in an alternative representation (e.g. an HTML payment page for
    ///     `Accept: text/html`). Defaults to `nil` (always `application/problem+json`).
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
        presenter: (any ChallengePresenter)? = nil,
        onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
    ) {
        self.minter = minter
        self.verifier = verifier
        offers = [MethodOffer(binding: binding, request: request)]
        self.expiresIn = expiresIn
        self.maxBodyBytes = maxBodyBytes
        self.authorizer = authorizer
        self.rateLimiter = rateLimiter
        self.idempotencyStore = idempotencyStore
        self.presenter = presenter
        self.rateLimitKey = rateLimitKey
        self.onEvent = onEvent
    }

    /// Creates a multi-method route from several ``MethodOffer``s, all minted and verified by the
    /// shared `minter`/`verifier` (whose registered methods must cover the offers). A `402` carries
    /// one `WWW-Authenticate` challenge per offer; a presented credential is verified against the
    /// offer whose `(realm, method, intent)` binding it matches. Pass a single offer for a
    /// one-method route (the primary initializer is the shortcut for that). Every other parameter
    /// matches the primary initializer.
    public init(
        minter: ChallengeMinter,
        verifier: PaymentVerifier,
        offers: [MethodOffer],
        expiresIn: TimeInterval? = 300,
        maxBodyBytes: Int = 10 * 1024 * 1024,
        authorizer: (any RequestAuthorizer)? = nil,
        rateLimiter: (any RateLimiter)? = nil,
        rateLimitKey: @escaping @Sendable (HTTPRequest) -> String? = { _ in nil },
        idempotencyStore: (any IdempotencyStore)? = nil,
        presenter: (any ChallengePresenter)? = nil,
        onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
    ) {
        precondition(!offers.isEmpty, "A route must offer at least one payment method")
        self.minter = minter
        self.verifier = verifier
        self.offers = offers
        self.expiresIn = expiresIn
        self.maxBodyBytes = maxBodyBytes
        self.authorizer = authorizer
        self.rateLimiter = rateLimiter
        self.idempotencyStore = idempotencyStore
        self.presenter = presenter
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
        /// No valid (or a retryable-`402`) credential; answer `402`, offering one retry challenge
        /// per payment method (each in its own `WWW-Authenticate` header) and the problem body. The
        /// array is never empty and its first element is the primary the problem body references.
        case challenge([Challenge], ProblemDetails)
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
    ///   - accept: The client's parsed `Accept-Payment` preferences (§7.4). An empty array (the
    ///     default) means "accept any", advertising every offer; otherwise only the accepted
    ///     methods are advertised, most-preferred first. HTTP-path only; non-HTTP callers omit it.
    /// - Returns: the ``Decision`` for the request. Emits a ``ServerEvent`` for the
    ///   minted-challenge, verified, and rejected branches.
    public func evaluate(
        authorization: String?,
        body: Data,
        now: Date,
        accept: [PaymentRange] = []
    ) async -> Decision {
        // Bound the body before any payment work, so an oversized request never
        // reaches credential parsing or digest hashing.
        if body.count > maxBodyBytes {
            return .payloadTooLarge
        }

        // §7.4: advertise only the methods the client accepts (Accept-Payment), most-preferred
        // first. An empty `accept` (absent header) leaves the offers unchanged.
        let active = negotiatedOffers(offers, for: accept)
        guard let authorization else {
            let challenges = mintChallenges(active, now: now)
            let problem = Self.problem(for: .freshChallenge, challengeID: challenges[0].id)
            return .challenge(challenges, problem)
        }

        // Verify against the offer whose binding the credential claims (so a multi-method route
        // pins each credential to its own method); fall back to the primary so a credential for an
        // unoffered method is rejected with a binding mismatch, not silently mis-pinned.
        let expecting = offer(matching: authorization)?.binding ?? offers[0].binding
        let outcome = await verifier.verify(
            authorization: authorization, body: body, now: now, expecting: expecting
        )
        switch outcome {
        case let .verified(verified):
            onEvent(.paymentVerified(verified))
            return .proceed(verified)
        case let .rejected(rejection):
            onEvent(.paymentRejected(rejection))
            // A 402 rejection re-offers every method a fresh retry challenge (each counted as
            // issued), so the client can correct its credential or switch methods. A terminal
            // 410/400 settlement problem (§10.5) offers none: it mints no challenge, fires no
            // `challengeIssued`, and embeds no `challengeId` (no challenge to retry on).
            if Self.problemStatus(for: rejection) == 402 {
                let challenges = mintChallenges(active, now: now)
                let problem = Self.problem(
                    for: .rejection(rejection),
                    challengeID: challenges[0].id
                )
                return .challenge(challenges, problem)
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
            onEvent(.idempotentReplay(key: key))
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
        // §7.4: honor the client's Accept-Payment preference when advertising offers. Multiple
        // header lines are combined (RFC 9110 §5.2: a list-based field); a malformed value is
        // treated as absent (accept-any), not a request error.
        let accept = (try? AcceptPayment.parse(
            request.headerFields[values: Self.acceptPaymentField].joined(separator: ", ")
        )) ?? []
        switch await evaluate(authorization: authorization, body: body, now: now, accept: accept) {
        case .payloadTooLarge:
            return guarded(Self.payloadTooLargeResponse(maxBodyBytes: maxBodyBytes))
        case let .challenge(challenges, problem):
            // The 402 advertises every offer (one WWW-Authenticate per challenge), and a presenter
            // receives them all so it can render one method or a chooser across several.
            if let presenter, let presented = await presenter.present(
                request, challenges: challenges, problem: problem
            ) {
                return guarded(
                    Self.paymentRequiredResponse(challenges: challenges, presented: presented)
                )
            }
            return guarded(Self.paymentRequiredResponse(challenges: challenges, problem: problem))
        case let .problem(problem):
            return guarded(Self.problemResponse(problem))
        case let .proceed(verified):
            return await served(serve(request, verified: verified, handler: handler))
        }
    }

    /// Mints one challenge per offer and emits a `challengeIssued` event for each, returning them
    /// in offer order (the first is the primary). Never empty: a route always has at least one
    /// offer.
    private func mintChallenges(_ offers: [MethodOffer], now: Date) -> [Challenge] {
        let expires = expiresIn.map { Expires(date: now.addingTimeInterval($0)) }
        return offers.map { offer in
            let challenge = minter.mint(
                binding: offer.binding,
                request: offer.request,
                expires: expires
            )
            onEvent(.challengeIssued(challenge))
            return challenge
        }
    }

    /// The offer whose binding matches the credential's echoed challenge, or `nil` if the
    /// credential is unparseable or its `(realm, method, intent)` is not one this route offers.
    private func offer(matching authorization: String) -> MethodOffer? {
        guard let credential = try? Credential(headerValue: authorization) else { return nil }
        let challenge = credential.challenge
        return offers.first {
            $0.binding.realm == challenge.realm
                && $0.binding.method == challenge.method
                && $0.binding.intent == challenge.intent
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

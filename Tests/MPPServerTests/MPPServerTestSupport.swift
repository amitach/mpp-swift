import Foundation
import HTTPTypes
import MPPCore
import MPPServer

// Shared fixtures for the MPPServerTests target, consolidated from per-file copies
// so the same secret / clock / route binding / middleware + credential builders are
// defined once. Internal (target-scoped), so every suite reuses them. Negative
// cases that need a different secret or binding pass one explicitly.

/// The default test signing secret.
let secret = Data("test-secret-key-12345".utf8)

/// A fixed test instant (2026-01-02T00:00:00Z).
let now = Date(timeIntervalSince1970: 1_767_312_000)

/// The (realm, method, intent) the server fixtures mint and verify for.
func makeBinding() throws -> RouteBinding {
    try RouteBinding(realm: "api.example.com", method: MethodName("tempo"), intent: .charge)
}

/// A middleware whose minter and verifier share one secret and replay store, with
/// any payment methods registered on the verifier.
func makeMiddleware(
    secret: Data = secret,
    store: any ReplayStore = InMemoryReplayStore(),
    methods: [any PaymentMethodServer] = [],
    maxBodyBytes: Int = 10 * 1024 * 1024,
    authorizer: (any RequestAuthorizer)? = nil,
    rateLimiter: (any RateLimiter)? = nil,
    rateLimitKey: @escaping @Sendable (HTTPRequest) -> String? = { _ in nil },
    idempotencyStore: (any IdempotencyStore)? = nil,
    onEvent: @escaping @Sendable (ServerEvent) -> Void = { _ in }
) throws -> MPPServerMiddleware {
    let signer = ChallengeSigner(secret: secret)
    return try MPPServerMiddleware(
        minter: ChallengeMinter(signer: signer),
        verifier: PaymentVerifier(signer: signer, replayStore: store, methods: methods),
        binding: makeBinding(),
        request: EncodedJSON("e30"),
        expiresIn: 300,
        maxBodyBytes: maxBodyBytes,
        authorizer: authorizer,
        rateLimiter: rateLimiter,
        rateLimitKey: rateLimitKey,
        idempotencyStore: idempotencyStore,
        onEvent: onEvent
    )
}

/// An `Authorization: Payment` value whose challenge is minted for the route.
func paidHeader() throws -> String {
    try headerFor()
}

/// A credential header minted with overridable secret/binding/expiry/digest, to
/// drive each `PaymentVerifier.Rejection` through the middleware. Defaults to a
/// future expiry (the verifier now requires one, see DIVERGING_FROM_SPEC in
/// `PaymentVerifier`); pass an explicit `expires` to drive the expired/no-expiry cases.
func headerFor(
    signedWith customSecret: Data? = nil,
    binding customBinding: RouteBinding? = nil,
    expires: Expires? = Expires(date: now.addingTimeInterval(3600)),
    digest: String? = nil
) throws -> String {
    let signer = ChallengeSigner(secret: customSecret ?? secret)
    let route = try customBinding ?? makeBinding()
    let challenge = ChallengeMinter(signer: signer).mint(
        binding: route, request: EncodedJSON("e30"), digest: digest, expires: expires
    )
    return try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
}

private let base64URLAlphabet = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)

/// The non-canonical base64url ids that decode to the SAME bytes as `id`. For a
/// 32-byte (256-bit) MAC the final character carries two unused ("don't care") low
/// bits, so the three alphabet characters sharing its top four bits encode the
/// identical bytes: the malleation a lenient base64 decoder lets through (CHID-1).
func sameMACVariants(of id: String) -> [String] {
    let chars = Array(id)
    guard let last = chars.last, let idx = base64URLAlphabet.firstIndex(of: last) else { return [] }
    let group = idx - (idx % 4) // start of the four chars sharing the top four bits
    return (1 ... 3).map { String(chars.dropLast()) + String(base64URLAlphabet[group + $0]) }
}

/// Builds a credential whose echoed challenge is signed by `signer`. Defaults to a
/// future expiry (the verifier now requires one, see DIVERGING_FROM_SPEC in
/// `PaymentVerifier`); pass `expires: nil` to drive the no-expiry rejection.
func signedCredential(
    signer: ChallengeSigner,
    digest: String? = nil,
    expires: Expires? = Expires(date: now.addingTimeInterval(3600))
) throws -> Credential {
    let unsigned = try Challenge(
        id: "unsigned", realm: "api.example.com", method: MethodName("tempo"),
        intent: .charge, request: EncodedJSON("e30"), digest: digest, expires: expires
    )
    let signed = unsigned.withID(signer.computeID(for: unsigned))
    return Credential(challenge: signed, payload: ["proof": "0xabc"])
}

/// The rejection reason from a verify outcome, or `nil` if it verified.
func rejection(_ outcome: PaymentVerifier.Outcome) -> PaymentVerifier.Rejection? {
    if case let .rejected(reason) = outcome { return reason }
    return nil
}

/// The verified token from a verify outcome, or `nil` if it was rejected.
func verified(_ outcome: PaymentVerifier.Outcome) -> MPPVerified? {
    if case let .verified(token) = outcome { return token }
    return nil
}

/// An `HTTPRequest` carrying an optional `Authorization` header.
func makeRequest(authorization: String? = nil) -> HTTPRequest {
    var fields = HTTPFields()
    if let authorization { fields[.authorization] = authorization }
    return HTTPRequest(
        method: .post,
        scheme: "https",
        authority: "api.example.com",
        path: "/r",
        headerFields: fields
    )
}

/// Collects the events a middleware emits during a request (the sink is synchronous).
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ServerEvent] = []
    func add(_ event: ServerEvent) {
        lock.lock(); stored.append(event); lock.unlock()
    }

    var events: [ServerEvent] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

func eventName(_ event: ServerEvent) -> String {
    switch event {
    case .challengeIssued: "challengeIssued"
    case .paymentVerified: "paymentVerified"
    case .paymentRejected: "paymentRejected"
    case .rateLimited: "rateLimited"
    case .idempotentReplay: "idempotentReplay"
    }
}

func lastEventName(_ box: EventBox) -> String? {
    box.events.last.map(eventName)
}

func eventNames(_ box: EventBox) -> [String] {
    box.events.map(eventName)
}

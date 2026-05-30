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
        onEvent: onEvent
    )
}

/// An `Authorization: Payment` value whose challenge is minted for the route.
func paidHeader() throws -> String {
    try headerFor()
}

/// A credential header minted with overridable secret/binding/expiry/digest, to
/// drive each `PaymentVerifier.Rejection` through the middleware.
func headerFor(
    signedWith customSecret: Data? = nil,
    binding customBinding: RouteBinding? = nil,
    expires: Expires? = nil,
    digest: String? = nil
) throws -> String {
    let signer = ChallengeSigner(secret: customSecret ?? secret)
    let route = try customBinding ?? makeBinding()
    let challenge = ChallengeMinter(signer: signer).mint(
        binding: route, request: EncodedJSON("e30"), digest: digest, expires: expires
    )
    return try Credential(challenge: challenge, payload: ["proof": "0xabc"]).headerValue
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

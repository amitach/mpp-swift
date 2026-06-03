import Foundation
import HTTPTypes
import Hummingbird
import MPPCore
import MPPHummingbird
import MPPServer
import MPPTempo
import MPPTempoServer
import NIOCore

// The live (FFI-gated) routes and their MPPClient/MPPEVM/MPPTempoFFI imports live in
// LiveConformanceRoutes.swift; this file is the proof + offline-subscription server plus main().

// A dev-only HTTP server exposing one zero-amount tempo/charge endpoint (and, under the FFI gate,
// a live-settling session endpoint) backed by MPPServerMiddleware + the MPPTempoServer verifiers.
// A foreign client (the mppx reference SDK) can thus pay our server over a real socket and have its
// proof verified by our code. The HTTP plumbing is Hummingbird via MPPHummingbird's GatedResponder
// (the same binding MPPProxy uses), not a hand-rolled socket loop. Not shipped: an executable with
// no product.

// The requested port (PORT=0 asks the OS for an ephemeral one). UInt16's failable
// string initializer returns nil for a non-numeric or out-of-range PORT, so a bad
// value falls back to the default rather than trapping. Internal (not private): the
// proxy conformance route pins the in-server origin URL to this port.
let requestedPort = ProcessInfo.processInfo.environment["PORT"]
    .flatMap(UInt16.init) ?? 8799
// Moderato testnet chain id, put in the challenge so a Tempo client signs for it.
// `chainId`/`secret`/`log` are internal (not private): the live routes in
// LiveConformanceRoutes.swift share them.
let chainId: UInt64 = 42431
let secret = Data("mpp-swift-reverse-conformance-secret-key-0123456789".utf8)
// CONFORMANCE_VERBOSE=1 logs the challenge issued and the credential verified, so a
// run shows the real data crossing the wire (useful for debugging interop).
private let verbose = ProcessInfo.processInfo.environment["CONFORMANCE_VERBOSE"] == "1"

func log(_ message: @autoclosure () -> String) {
    // fflush(nil) flushes all streams without referencing the global `stdout` var,
    // which is not concurrency-safe under Swift 6 on Glibc.
    if verbose { print(message()); fflush(nil) }
}

/// The fixed paid resource every gated route returns once a payment verifies.
private let paidBody: @Sendable (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data) = { _, _ in
    (HTTPResponse(status: .ok), Data(#"{"ok":true,"paid":true}"#.utf8))
}

// Internal (not private): the proxy conformance route in ProxyConformanceRoutes.swift reuses this
// same zero-amount Tempo charge gate, so a proxy-gated route verifies an mppx proof exactly as the
// direct /proof route does.
func makeMiddleware() throws -> MPPServerMiddleware {
    let request = EncodedJSON(json: .object([
        "amount": .string("0"),
        "methodDetails": .object(["chainId": .integer(Int64(chainId))]),
    ]))
    return try MPPServerMiddleware.make(
        secret: secret,
        binding: RouteBinding(realm: "127.0.0.1", method: MethodName("tempo"), intent: .charge),
        request: request, methods: [TempoProofVerifier()]
    ) { event in
        switch event {
        case let .challengeIssued(challenge):
            log("[server] issued 402  id=\(challenge.id)")
            log("[server]              realm=\(challenge.realm) method=\(challenge.method.rawValue)"
                + " intent=\(challenge.intent.rawValue)")
            log("[server]              request(b64url)=\(challenge.request.rawValue)")
        case let .paymentVerified(verified):
            log("[server] VERIFIED     source=\(verified.credential?.source ?? "nil")")
        case let .paymentRejected(rejection):
            log("[server] rejected     \(rejection)")
        }
    }
}

// Reverse subscription conformance: the mppx CLIENT signs a TempoKeyAuthorization delegating
// the access key OUR 402 issued, and OUR TempoSubscriptionVerifier verifies it. Offline (no
// chain), so it is un-gated and always registered. The whole-second `.000Z` expiry is the form
// `Date.toISOString()` emits, exercising the interop-tolerant parse in the reverse direction too.
private let subscriptionCurrencyHex = "0x20c0000000000000000000000000000000000001"
// Internal (not private): the live subscription route in LiveConformanceRoutes.swift reuses it.
let subscriptionRecipientHex = "0x1111111111111111111111111111111111111111"
private let subscriptionLookupKey = "conformance-subscription"

private func makeSubscriptionMiddleware() async throws -> MPPServerMiddleware {
    // Provision the access key the subscription delegates to and embed its address in the 402; the
    // mppx client reads it and signs a key authorization for it. The store also holds the private
    // key for renewal signing (this offline reverse-conformance only verifies the authorization).
    let accessKeys = InMemoryAccessKeyStore()
    let accessKeyAddress = try await accessKeys.provision(forLookupKey: subscriptionLookupKey)
    let request = EncodedJSON(json: .object([
        "amount": .string("1000000"),
        "currency": .string(subscriptionCurrencyHex),
        "recipient": .string(subscriptionRecipientHex),
        "periodCount": .string("30"),
        "periodUnit": .string("day"),
        "subscriptionExpires": .string("2030-01-01T00:00:00.000Z"),
        "methodDetails": .object([
            "accessKey": .object([
                "accessKeyAddress": .string(accessKeyAddress.checksummed),
                "keyType": .string("secp256k1"),
            ]),
            "chainId": .integer(Int64(chainId)),
        ]),
    ]))
    // The activating verifier persists the verified subscription into the store on verify (the
    // engine's renewer is unused here: this offline reverse-conformance activates, never renews).
    let subscriptions = SubscriptionEngine(
        store: InMemorySubscriptionStore(), renewer: ConformanceNoopRenewer()
    )
    let activating = ActivatingSubscriptionVerifier(
        verifier: TempoSubscriptionVerifier(defaultChainID: chainId),
        engine: subscriptions
    ) { credential in
        .init(subscriptionID: credential.challenge.id, lookupKey: subscriptionLookupKey)
    }
    return try MPPServerMiddleware.make(
        secret: secret,
        binding: RouteBinding(
            realm: "127.0.0.1",
            method: MethodName("tempo"),
            intent: .subscription
        ),
        request: request, methods: [activating]
    ) { event in
        switch event {
        case let .challengeIssued(challenge):
            log("[server] issued 402 (subscription) id=\(challenge.id)")
        case let .paymentVerified(verified):
            log("[server] ACTIVATED (subscription) source=\(verified.credential?.source ?? "nil")")
        case let .paymentRejected(rejection):
            log("[server] rejected (subscription) \(rejection)")
        }
    }
}

/// A no-op renewer for the offline conformance server, which activates subscriptions but never
/// drives a recurring charge (so the engine's renewer is never invoked).
private struct ConformanceNoopRenewer: SubscriptionRenewer {
    func charge(_: SubscriptionRecord, period _: Int, idempotencyReference: String) -> String {
        idempotencyReference
    }
}

/// Logs what the server received on a request: the method/path, and (when a
/// credential is present) the decoded challenge id, source DID, and proof payload.
func logIncoming(_ request: HTTPRequest) {
    guard verbose else { return }
    guard let auth = request.headerFields[.authorization] else {
        log("[server] <- \(request.method.rawValue) \(request.path ?? "") (no credential)")
        return
    }
    log("[server] <- \(request.method.rawValue) \(request.path ?? "") (Authorization: Payment)")
    guard let credential = try? Credential(headerValue: auth) else { return }
    log("[server]    credential.challenge.id = \(credential.challenge.id)")
    log("[server]    credential.source       = \(credential.source ?? "nil")")
    if case let .string(type)? = credential.payload["type"] {
        log("[server]    credential.payload.type = \(type)")
    }
    if case let .string(signature)? = credential.payload["signature"] {
        log("[server]    credential.payload.signature = \(signature)")
    }
}

@main
enum ConformanceServer {
    static func main() async throws {
        guard #available(macOS 14, iOS 17, tvOS 17, visionOS 1, *) else {
            fatalError("MPPConformanceServer requires macOS 14+ (Hummingbird 2 runtime)")
        }
        let proofGate = try makeMiddleware()
        let proofResponder = GatedResponder<BasicRequestContext>(gate: proofGate, handler: paidBody)

        let router = Router()
        // The mppx reference client GETs these paths; the gate handles the 402/verify handshake.
        // Registered for GET and POST so a client using either verb is served (the old raw-socket
        // server was method-agnostic).
        register(proofResponder, on: router, path: "proof")

        // Subscription reverse conformance is offline, so it is always available.
        let subscriptionGate = try await makeSubscriptionMiddleware()
        let subscriptionResponder = GatedResponder<BasicRequestContext>(
            gate: subscriptionGate, handler: paidBody
        )
        register(subscriptionResponder, on: router, path: "subscription")

        // Proxy conformance: the mppx client pays GET /proxy/echo/resource THROUGH our MPPProxy,
        // which forwards the verified request to a free in-server origin (see
        // ProxyConformanceRoutes.swift). The proxy pins its origin URL to the bound port, so it is
        // mounted only for a fixed PORT (run-proxy.sh sets one); a PORT=0 ephemeral run, used only
        // by the direct routes, skips it rather than mounting an unreachable :0 origin.
        if requestedPort != 0 {
            try registerProxyConformance(on: router)
        }

        #if MPP_TEMPO_FFI_ENABLED
            if let sessionGate = try await makeSessionMiddleware() {
                let sessionResponder = GatedResponder<BasicRequestContext>(
                    gate: sessionGate, handler: paidBody
                )
                register(sessionResponder, on: router, path: "session")
            }
            if let liveSubscriptionGate = try await makeSubscriptionLiveMiddleware() {
                let responder = GatedResponder<BasicRequestContext>(
                    gate: liveSubscriptionGate, handler: paidBody
                )
                register(responder, on: router, path: "subscription-live")
            }
        #endif

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: Int(requestedPort))),
            onServerRunning: { channel in
                // The run scripts wait for "listening" and parse the bound port from this line
                // (PORT=0 asks the OS for an ephemeral one, so the requested port is not
                // authoritative).
                let port = channel.localAddress?.port ?? Int(requestedPort)
                print("reverse-conformance-server listening http://127.0.0.1:\(port)/proof")
                fflush(nil)
            }
        )
        try await app.runService()
    }

    /// Registers `responder` for GET and POST on `path`, logging each incoming request when
    /// verbose.
    @available(macOS 14, iOS 17, tvOS 17, visionOS 1, *)
    private static func register(
        _ responder: GatedResponder<BasicRequestContext>,
        on router: Router<BasicRequestContext>,
        path: RouterPath
    ) {
        for method in [HTTPRequest.Method.get, .post] {
            router.on(path, method: method) { request, context in
                logIncoming(request.head)
                return try await responder.respond(to: request, context: context)
            }
        }
    }
}

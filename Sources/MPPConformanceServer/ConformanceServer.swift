import Foundation
import HTTPTypes
import Hummingbird
import MPPCore
import MPPHummingbird
import MPPServer
import MPPTempo
import MPPTempoServer
import NIOCore

// MPPClient/MPPEVM/MPPTempoFFI are used only by the FFI-gated session route, so they (and
// their imports) ride the gate; the default proof-only server depends on neither.
#if MPP_TEMPO_FFI_ENABLED
    import MPPClient
    import MPPEVM
    import MPPTempoFFI
#endif

// A dev-only HTTP server exposing one zero-amount tempo/charge endpoint (and, under the FFI gate,
// a live-settling session endpoint) backed by MPPServerMiddleware + the MPPTempoServer verifiers.
// A foreign client (the mppx reference SDK) can thus pay our server over a real socket and have its
// proof verified by our code. The HTTP plumbing is Hummingbird via MPPHummingbird's GatedResponder
// (the same binding MPPProxy uses), not a hand-rolled socket loop. Not shipped: an executable with
// no product.

// The requested port (PORT=0 asks the OS for an ephemeral one). UInt16's failable
// string initializer returns nil for a non-numeric or out-of-range PORT, so a bad
// value falls back to the default rather than trapping.
private let requestedPort = ProcessInfo.processInfo.environment["PORT"]
    .flatMap(UInt16.init) ?? 8799
// Moderato testnet chain id, put in the challenge so a Tempo client signs for it.
private let chainId: UInt64 = 42431
private let secret = Data("mpp-swift-reverse-conformance-secret-key-0123456789".utf8)
// CONFORMANCE_VERBOSE=1 logs the challenge issued and the credential verified, so a
// run shows the real data crossing the wire (useful for debugging interop).
private let verbose = ProcessInfo.processInfo.environment["CONFORMANCE_VERBOSE"] == "1"

private func log(_ message: @autoclosure () -> String) {
    // fflush(nil) flushes all streams without referencing the global `stdout` var,
    // which is not concurrency-safe under Swift 6 on Glibc.
    if verbose { print(message()); fflush(nil) }
}

/// The fixed paid resource every gated route returns once a payment verifies.
private let paidBody: @Sendable (HTTPRequest, MPPVerified) async -> (HTTPResponse, Data) = { _, _ in
    (HTTPResponse(status: .ok), Data(#"{"ok":true,"paid":true}"#.utf8))
}

private func makeMiddleware() throws -> MPPServerMiddleware {
    let signer = ChallengeSigner(secret: secret)
    let binding = try RouteBinding(
        realm: "127.0.0.1", method: MethodName("tempo"), intent: .charge
    )
    let request = EncodedJSON(json: .object([
        "amount": .string("0"),
        "methodDetails": .object(["chainId": .integer(Int64(chainId))]),
    ]))
    return MPPServerMiddleware(
        minter: ChallengeMinter(signer: signer),
        verifier: PaymentVerifier(
            signer: signer, replayStore: InMemoryReplayStore(), methods: [TempoProofVerifier()]
        ),
        binding: binding,
        request: request
    ) { event in
        switch event {
        case let .challengeIssued(challenge):
            log("[server] issued 402  id=\(challenge.id)")
            log("[server]              realm=\(challenge.realm) method=\(challenge.method.rawValue)"
                + " intent=\(challenge.intent.rawValue)")
            log("[server]              request(b64url)=\(challenge.request.rawValue)")
        case let .paymentVerified(verified):
            log("[server] VERIFIED     source=\(verified.credential.source ?? "nil")")
        case let .paymentRejected(rejection):
            log("[server] rejected     \(rejection)")
        }
    }
}

#if MPP_TEMPO_FFI_ENABLED
    // Reverse session conformance (live on Moderato). The mppx CLIENT opens a channel to
    // our recipient, vouchers, and closes; our SessionMethod relays the open, accepts the
    // vouchers, and settles the close on-chain with the faucet-funded operator key. Gated
    // on the FFI (the close builder) and on CONFORMANCE_OPERATOR_KEY being set.
    private let moderatoRPCURL = "https://rpc.moderato.tempo.xyz"
    private let sessionEscrowHex = "0xe1c4d3dce17bc111181ddf716f75bae49e61a336"
    private let sessionTokenHex = "0x20c0000000000000000000000000000000000000"

    private enum SessionConfigError: Error { case badOperatorKey }

    /// Resolves the on-chain relay/settle provider and the operator (payee) address from the
    /// faucet-funded operator key, or nil if no key is configured (proof-only run).
    private func makeSessionProvider()
        async throws -> (provider: RPCChannelStateProvider, payee: EthereumAddress)? {
        guard let keyHex = ProcessInfo.processInfo.environment["CONFORMANCE_OPERATOR_KEY"],
              let keyData = Data(hexPrefixed: keyHex)
        else { return nil }
        let operatorSigner = try Secp256k1Signer(privateKey: keyData)
        guard let payee = EthereumAddress(uncompressedPublicKey: operatorSigner.publicKey),
              let rpcURL = URL(string: moderatoRPCURL)
        else { throw SessionConfigError.badOperatorKey }
        let rpc = try EVMRPC(transport: URLSessionTransport(), url: rpcURL)
        let gasPrice = try await rpc.gasPrice()
        let builder = FFITempoTxBuilder(
            signingKey: keyData,
            fee: TempoFeeParameters(
                maxFeePerGas: String(gasPrice * 2),
                maxPriorityFeePerGas: "0",
                gasLimit: 2_000_000,
                feeToken: nil
            ),
            nonceProvider: { try await rpc.transactionCount($0) }
        )
        return (RPCChannelStateProvider(rpc: rpc, closeTxBuilder: builder), payee)
    }

    /// Builds the session middleware, or nil if no operator key is configured (proof-only).
    private func makeSessionMiddleware() async throws -> MPPServerMiddleware? {
        guard let (provider, payee) = try await makeSessionProvider() else { return nil }
        let sessionMethod = SessionMethod(
            provider: provider, store: InMemoryChannelStore(), defaultChainID: chainId
        )
        let signer = ChallengeSigner(secret: secret)
        let binding = try RouteBinding(
            realm: "127.0.0.1", method: MethodName("tempo"), intent: .session
        )
        // The session 402 the mppx client opens against: amount + payee (our operator) +
        // currency + a top-level suggestedDeposit + methodDetails.{chainId, escrowContract}.
        let request = EncodedJSON(json: .object([
            "amount": .string("1"),
            "recipient": .string(payee.checksummed),
            "currency": .string(sessionTokenHex),
            "suggestedDeposit": .string("1000"),
            "methodDetails": .object([
                "chainId": .integer(Int64(chainId)),
                "escrowContract": .string(sessionEscrowHex),
            ]),
        ]))
        return MPPServerMiddleware(
            minter: ChallengeMinter(signer: signer),
            // A normal one-time replay store is fine: SessionMethod.reusesChallenge tells the
            // verifier not to consume the challenge id (the channel cumulative is the
            // anti-replay), so the same challenge serves open, vouchers, and close.
            verifier: PaymentVerifier(
                signer: signer, replayStore: InMemoryReplayStore(), methods: [sessionMethod]
            ),
            binding: binding,
            request: request
        ) { event in
            switch event {
            case let .challengeIssued(challenge):
                log("[server] issued 402 (session) id=\(challenge.id)")
            case let .paymentVerified(verified):
                log("[server] VERIFIED (session) source=\(verified.credential.source ?? "nil")")
            case let .paymentRejected(rejection):
                log("[server] rejected (session) \(rejection)")
            }
        }
    }
#endif

/// Logs what the server received on a request: the method/path, and (when a
/// credential is present) the decoded challenge id, source DID, and proof payload.
private func logIncoming(_ request: HTTPRequest) {
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

        #if MPP_TEMPO_FFI_ENABLED
            if let sessionGate = try await makeSessionMiddleware() {
                let sessionResponder = GatedResponder<BasicRequestContext>(
                    gate: sessionGate, handler: paidBody
                )
                register(sessionResponder, on: router, path: "session")
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

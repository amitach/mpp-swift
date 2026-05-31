import Foundation
import MCP
import MPPClient
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer
import Testing
@testable import MPPMCP

// Shared fixtures for the MPPMCP test target (one home, not per-file copies). The Tempo
// zero-amount proof is the payment method exercised end to end: identity-only (ecrecover), no
// RPC, deterministic. Mirrors the construction in the MPPTempoServer proof tests.

let mcpRealm = "https://api.example.com"
let mcpNow = Date(timeIntervalSince1970: 1_767_312_000)
let mcpSecret = Data("mpp-swift-mcp-conformance-fixed-secret-key-0123".utf8)

func mcpSigner(byte: UInt8 = 1) throws -> Secp256k1Signer {
    try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [byte]))
}

func mcpProofMethod(byte: UInt8 = 1) throws -> TempoProofMethod {
    try #require(TempoProofMethod(signer: mcpSigner(byte: byte)))
}

func mcpChargeRequest(amount: String = "0") -> EncodedJSON {
    EncodedJSON(json: .object([
        "amount": .string(amount),
        "methodDetails": .object(["chainId": .integer(Int64(TempoChain.mainnet))]),
    ]))
}

func mcpMiddleware() throws -> MPPServerMiddleware {
    try MPPServerMiddleware(
        minter: ChallengeMinter(signer: ChallengeSigner(secret: mcpSecret)),
        verifier: PaymentVerifier(
            signer: ChallengeSigner(secret: mcpSecret),
            replayStore: InMemoryReplayStore(),
            methods: [TempoProofVerifier()]
        ),
        binding: RouteBinding(realm: mcpRealm, method: MethodName("tempo"), intent: .charge),
        request: mcpChargeRequest()
    )
}

/// A gate over a fresh middleware (own replay store) on the fixed test clock.
func mcpGate(
    _ inner: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
) throws -> @Sendable (CallTool.Parameters) async throws -> CallTool.Result {
    try MCPPaymentServer(middleware: mcpMiddleware(), now: { mcpNow }).gated(inner)
}

/// Mints a challenge (same secret/binding/request the gate verifies against) and pays it,
/// returning the `params._meta` a client would send.
func mcpCredentialMeta(byte: UInt8 = 1) async throws -> Metadata {
    let minter = ChallengeMinter(signer: ChallengeSigner(secret: mcpSecret))
    let challenge = try minter.mint(
        binding: RouteBinding(realm: mcpRealm, method: MethodName("tempo"), intent: .charge),
        request: mcpChargeRequest()
    )
    let credential = try await mcpProofMethod(byte: byte).buildCredential(for: challenge)
    return try Metadata(additionalFields: [
        MCPPayment.credentialMetaKey: MCPPaymentCodec.value(for: credential),
    ])
}

/// Stands up a connected in-process MCP server with an arbitrary `tools/call` handler and an
/// `MCPPaymentClient` over `InMemoryTransport`.
func makeMCPPair(
    clientMethods: [any PaymentMethodClient],
    handler: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
) async throws -> MCPPaymentClient {
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let server = Server(name: "mpp-mcp-test", version: "1.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(CallTool.self, handler: handler)
    try await server.start(transport: serverTransport)

    let client = Client(name: "mpp-mcp-test-client", version: "1.0")
    _ = try await client.connect(transport: clientTransport)
    return MCPPaymentClient(client: client, methods: clientMethods)
}

/// The common case: a server gating a single `premium` tool behind payment.
func makeMCPPaymentPair(
    clientMethods: [any PaymentMethodClient]
) async throws -> MCPPaymentClient {
    let gate = try MCPPaymentServer(middleware: mcpMiddleware(), now: { mcpNow })
    return try await makeMCPPair(
        clientMethods: clientMethods,
        handler: gate.gated { params in
            CallTool.Result(content: [
                .text(text: "premium content for \(params.name)", annotations: nil, _meta: nil),
            ])
        }
    )
}

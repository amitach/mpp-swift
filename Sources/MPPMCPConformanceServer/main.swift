import Foundation
import MCP
import MPPCore
import MPPMCP
import MPPServer
import MPPTempoServer

// A dev-only MCP server over stdio that gates a `premium` tool behind a zero-amount Tempo proof,
// via MPPMCP. The reference mppx `mcp-sdk` CLIENT (Scripts/conformance/mcp-client.mjs) spawns this
// and pays it, proving the JSON-RPC / MCP payment binding interoperates with the real peer over a
// real stdio transport. Not a shipped product. Only stdout carries the JSON-RPC protocol (the
// StdioTransport's logger is a no-op), so nothing here writes to stdout.

// Fixed HMAC secret for a deterministic harness (a test-only secret, not a real credential).
let secret = Data("mpp-swift-conformance-harness-fixed-secret-key-0123456789".utf8)

let middleware = try MPPServerMiddleware(
    minter: ChallengeMinter(signer: ChallengeSigner(secret: secret)),
    verifier: PaymentVerifier(
        signer: ChallengeSigner(secret: secret),
        replayStore: InMemoryReplayStore(),
        methods: [TempoProofVerifier()]
    ),
    binding: RouteBinding(realm: "mpp-swift", method: MethodName("tempo"), intent: .charge),
    // The zero-amount charge request (the EIP-712 proof path): amount "0" plus the
    // recipient/currency/chainId a tempo charge carries, matching the reference server's shape.
    request: EncodedJSON(json: .object([
        "amount": .string("0"),
        "recipient": .string("0xC0ffee0000000000000000000000000000000001"),
        "currency": .string("0x20c0000000000000000000000000000000000000"),
        "methodDetails": .object(["chainId": .integer(42431)]),
    ]))
)

let gate = MCPPaymentServer(middleware: middleware)

let server = Server(
    name: "mpp-swift-mcp-conformance",
    version: "1.0",
    capabilities: .init(tools: .init())
)

await server.withMethodHandler(CallTool.self, handler: gate.gated { params in
    CallTool.Result(content: [
        .text(text: "premium content for \(params.name)", annotations: nil, _meta: nil),
    ])
})

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()

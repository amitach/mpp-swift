import Foundation
import MCP
import MPPCore
import MPPEVM
import MPPMCP
import MPPTempo

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

// A dev-only MCP client that spawns the reference mppx `mcp-sdk` server
// (Scripts/conformance/mcp-server.mjs) over stdio and pays its payment-gated `premium` tool with a
// zero-amount Tempo proof, via MPPMCP's MCPPaymentClient. The reverse of MPPMCPConformanceServer.
// Not a shipped product. PASS/FAIL is reported on this process's stdout; the MCP protocol flows
// over the pipes to the subprocess, and the server's logs go to our stderr.
//
// Known gap: mppx emits -32042 with data.challenges. The pinned MCP SDK (swift-sdk #291) decodes
// every -32042 as MCPError.urlElicitationRequired and keeps only data.elicitations, so this
// client cannot read the challenge. The wire codes are unchanged on purpose. Re-run once the SDK
// preserves data.challenges on -32042. Forward conformance (mppx paying our server) is unaffected.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let serverScript = ProcessInfo.processInfo.environment["MPPX_MCP_SERVER"] else {
    fail("MPPX_MCP_SERVER not set (path to mcp-server.mjs)")
}

// Spawn the mppx mcp-sdk server: we write to its stdin, read from its stdout.
let toServer = Pipe()
let fromServer = Pipe()
let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
server.arguments = ["node", serverScript]
server.standardInput = toServer
server.standardOutput = fromServer
server.standardError = FileHandle.standardError
do {
    try server.run()
} catch {
    fail("could not spawn the mppx mcp-sdk server: \(error)")
}

let transport = StdioTransport(
    input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
    output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor)
)
let client = Client(name: "mpp-swift-mcp-conformance-client", version: "1.0")
_ = try await client.connect(transport: transport)

let signer = try Secp256k1Signer(privateKey: Data([UInt8](repeating: 0, count: 31) + [0x22]))
guard let method = TempoProofMethod(signer: signer) else {
    fail("could not derive the Tempo proof method")
}

let payClient = MCPPaymentClient(client: client, methods: [method])
let paid: MCPPaymentClient.PaidResult
do {
    paid = try await payClient.callTool(name: "premium")
} catch let error as MCPError {
    if case .urlElicitationRequired = error, error.code == MCPPayment.paymentRequiredCode {
        server.terminate()
        fail(
            "FAIL: the MCP SDK decoded mppx's -32042 as urlElicitationRequired and dropped "
                + "data.challenges (swift-sdk #291). MCPPaymentClient cannot pay until that "
                + "data is preserved."
        )
    }
    server.terminate()
    fail("FAIL: \(error)")
}

guard let receipt = paid.receipt else {
    server.terminate()
    fail("FAIL: no receipt on the paid result")
}

print("PASS: our Swift MCP client paid the mppx mcp-sdk server over stdio")
print("  receipt method: \(receipt.method.rawValue), reference: \(receipt.reference)")
server.terminate()

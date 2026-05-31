import Foundation
import MCP
import MPPClient
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
// zero-amount Tempo proof, via MPPMCP's MCPPaymentClient. The reverse of MPPMCPConformanceServer:
// it proves our client interoperates with the real peer's MCP server over a real transport. Not a
// shipped product. PASS/FAIL is reported on this process's stdout; the MCP protocol flows over the
// pipes to the subprocess, and the server's logs go to our stderr.

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
let paid = try await payClient.callTool(name: "premium")

guard let receipt = paid.receipt else {
    server.terminate()
    fail("FAIL: no receipt on the paid result")
}

print("PASS: our Swift MCP client paid the mppx mcp-sdk server over stdio")
print("  receipt method: \(receipt.method.rawValue), reference: \(receipt.reference)")
server.terminate()

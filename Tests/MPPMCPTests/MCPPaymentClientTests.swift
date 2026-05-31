import MCP
import MPPCore
import Testing
@testable import MPPMCP

// Client-level coverage, mirroring mppx's `mcp-sdk/client/McpClient.test.ts` scenarios
// (pass-through, non-payment errors, no-method) against our `MCPPaymentClient`.
@Suite("MCP payment client")
struct MCPPaymentClientTests {
    @Test("passes through a call that needs no payment, with no receipt")
    func passThrough() async throws {
        let payClient = try await makeMCPPair(clientMethods: [mcpProofMethod()]) { _ in
            CallTool.Result(content: [.text(text: "free", annotations: nil, _meta: nil)])
        }
        let paid = try await payClient.callTool(name: "free")
        #expect(paid.receipt == nil)
        if case let .text(text, _, _) = paid.result.content.first {
            #expect(text == "free")
        } else {
            Issue.record("expected text content")
        }
    }

    @Test("a tool-level isError result passes through unchanged (not a payment error)")
    func isErrorPassesThrough() async throws {
        let payClient = try await makeMCPPair(clientMethods: [mcpProofMethod()]) { _ in
            CallTool.Result(
                content: [.text(text: "boom", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let paid = try await payClient.callTool(name: "broken")
        #expect(paid.result.isError == true)
        #expect(paid.receipt == nil)
    }

    @Test("a non-payment protocol error is rethrown, never treated as payment")
    func nonPaymentErrorRethrown() async throws {
        let payClient = try await makeMCPPair(clientMethods: [mcpProofMethod()]) { _ in
            throw MCPError.invalidParams("bad arguments")
        }
        do {
            _ = try await payClient.callTool(name: "premium")
            Issue.record("expected the invalidParams error to propagate")
        } catch let error as MCPError {
            #expect(error.code == -32602)
        }
    }
}

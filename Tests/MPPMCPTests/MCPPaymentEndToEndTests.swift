import MCP
import MPPCore
import Testing
@testable import MPPMCP

@Suite("MCP payment end-to-end")
struct MCPPaymentEndToEndTests {
    @Test("client transparently pays a gated tool and reads the receipt")
    func paysAndReadsReceipt() async throws {
        let payClient = try await makeMCPPaymentPair(clientMethods: [mcpProofMethod()])
        let paid = try await payClient.callTool(name: "premium")

        #expect(paid.result.isError != true)
        #expect(paid.receipt != nil)
        #expect(paid.receipt?.method.rawValue == "tempo")
        if case let .text(text, _, _) = paid.result.content.first {
            #expect(text.contains("premium content"))
        } else {
            Issue.record("expected text content, got \(paid.result.content)")
        }
    }

    @Test("a client with no supporting method surfaces the original payment-required error")
    func noSupportingMethod() async throws {
        let payClient = try await makeMCPPaymentPair(clientMethods: [])
        await #expect(throws: MCPError.self) {
            _ = try await payClient.callTool(name: "premium")
        }
        do {
            _ = try await payClient.callTool(name: "premium")
            Issue.record("expected a paymentRequired error")
        } catch let error as MCPError {
            guard case let .paymentRequired(code, _, _) = error else {
                Issue.record("expected .paymentRequired, got \(error)"); return
            }
            #expect(code == MCPPayment.paymentRequiredCode)
        }
    }

    @Test("a replayed challenge is rejected: the second identical call fails verification")
    func replayRejected() async throws {
        let payClient = try await makeMCPPaymentPair(clientMethods: [mcpProofMethod()])
        // First call consumes the (deterministic) challenge id.
        _ = try await payClient.callTool(name: "premium")
        // The second call mints the same id (fixed clock + fixed request), so the paid retry is
        // a replay -> the server answers -32043 (verification failed), which propagates.
        do {
            _ = try await payClient.callTool(name: "premium")
            Issue.record("expected a replay rejection")
        } catch let error as MCPError {
            guard case let .paymentRequired(code, _, _) = error else {
                Issue.record("expected .paymentRequired, got \(error)"); return
            }
            #expect(code == MCPPayment.verificationFailedCode)
        }
    }
}

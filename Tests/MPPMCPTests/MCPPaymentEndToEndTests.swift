import MCP
import Testing
@testable import MPPMCP

@Suite("MCP payment end-to-end")
struct MCPPaymentEndToEndTests {
    @Test("client pays a preserved challenge and the real gate verifies it")
    func paysPreservedChallenge() async throws {
        // -32043 survives MCPError's decoder as serverErrorWithData. The paid retry goes
        // through MCPPaymentServer, so the receipt is the one the gate mints (its reference
        // is the verified challenge id). -32042 does not survive decode; that gap is pinned
        // by `peerCompatibleChallengeIsNotPayable`.
        let payClient = try await makePreservedPaymentPair(clientMethods: [mcpProofMethod()])
        let paid = try await payClient.callTool(name: "premium")

        #expect(paid.result.isError != true)
        let receipt = try #require(paid.receipt)
        #expect(receipt.method.rawValue == "tempo")
        #expect(receipt.extras[MCPPaymentCodec.challengeIDKey] == .string(receipt.reference))
        if case let .text(text, _, _) = paid.result.content.first {
            #expect(text.contains("premium content"))
        } else {
            Issue.record("expected text content, got \(paid.result.content)")
        }
    }

    @Test("a client with no supporting method surfaces the original preserved payment error")
    func noSupportingMethod() async throws {
        let payClient = try await makePreservedPaymentPair(clientMethods: [])
        do {
            _ = try await payClient.callTool(name: "premium")
            Issue.record("expected the payment error to propagate")
        } catch let error as MCPError {
            guard case let .serverErrorWithData(code, _, data) = error else {
                Issue.record("expected .serverErrorWithData, got \(error)"); return
            }
            #expect(code == MCPPayment.verificationFailedCode)
            let object = try #require(data.objectValue)
            let challenges = try MCPPaymentCodec.challenges(fromErrorData: object)
            #expect(challenges.count == 1)
        }
    }

    @Test("a decoded peer-compatible -32042 is not payable: the SDK drops data.challenges")
    func peerCompatibleChallengeIsNotPayable() async throws {
        // The real gate emits -32042 with data.challenges. InMemoryTransport JSON-encodes that
        // MCPError and the client decodes it. #291 maps every -32042 to urlElicitationRequired
        // and keeps only data.elicitations, so the pay loop never starts. If a future SDK
        // preserves the frame as serverErrorWithData, this test fails and the client will pay.
        let payClient = try await makeMCPPaymentPair(clientMethods: [mcpProofMethod()])
        do {
            _ = try await payClient.callTool(name: "premium")
            Issue.record("expected the decoded -32042 to surface, not a paid result")
        } catch let error as MCPError {
            guard case .urlElicitationRequired = error else {
                Issue.record("expected .urlElicitationRequired, got \(error)"); return
            }
            #expect(error.code == MCPPayment.paymentRequiredCode)
        }
    }
}

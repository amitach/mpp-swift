import MCP
import MPPCore
import Testing
@testable import MPPMCP

// Gate-level coverage, mirroring mppx's `mcp-sdk/server/Transport.test.ts` scenarios
// (respondChallenge / respondReceipt / getCredential) against our `MCPPaymentServer.gated`.
@Suite("MCP payment server gate")
struct MCPPaymentServerGateTests {
    private func okHandler(
        meta: Metadata? = nil
    ) -> @Sendable (CallTool.Parameters) async throws -> CallTool.Result {
        { _ in CallTool.Result(
            content: [.text(text: "ok", annotations: nil, _meta: meta)],
            _meta: meta
        ) }
    }

    private func paymentRequired(_ error: Error) -> (code: Int, data: [String: Value])? {
        guard let mcp = error as? MCPError, case let .paymentRequired(code, _, data) = mcp else {
            return nil
        }
        return (code, data)
    }

    @Test("no credential in _meta answers -32042 with the challenge in error.data")
    func noCredentialChallenge() async throws {
        let handler = try mcpGate(okHandler())
        do {
            _ = try await handler(CallTool.Parameters(name: "premium"))
            Issue.record("expected paymentRequired")
        } catch {
            guard let (code, data) = paymentRequired(error) else {
                Issue.record("expected .paymentRequired, got \(error)"); return
            }
            #expect(code == MCPPayment.paymentRequiredCode)
            let challenges = try MCPPaymentCodec.challenges(fromErrorData: data)
            #expect(challenges.count == 1)
            #expect(challenges.first?.method.rawValue == "tempo")
            #expect(data["httpStatus"] == .int(402))
        }
    }

    @Test("a _meta without the credential key is treated as no credential")
    func missingCredentialKey() async throws {
        let handler = try mcpGate(okHandler())
        let meta = Metadata(additionalFields: ["unrelated": .string("x")])
        do {
            _ = try await handler(CallTool.Parameters(name: "premium", meta: meta))
            Issue.record("expected paymentRequired")
        } catch {
            #expect(paymentRequired(error)?.code == MCPPayment.paymentRequiredCode)
        }
    }

    @Test("a valid credential proceeds and the receipt is attached to result._meta")
    func validCredentialProceeds() async throws {
        let handler = try mcpGate(okHandler())
        let params = try await CallTool.Parameters(name: "premium", meta: mcpCredentialMeta())
        let result = try await handler(params)
        #expect(result.isError != true)
        let receiptValue = try #require(result._meta?[MCPPayment.receiptMetaKey])
        let receipt = try MCPPaymentCodec.receipt(from: receiptValue)
        #expect(receipt.method.rawValue == "tempo")
        // The receipt carries the challengeId per the MCP binding.
        #expect(receiptValue.objectValue?[MCPPaymentCodec.challengeIDKey] != nil)
    }

    @Test("a replayed credential answers -32043 with a problem")
    func replayedCredential() async throws {
        let handler = try mcpGate(okHandler())
        let meta = try await mcpCredentialMeta()
        _ = try await handler(CallTool.Parameters(name: "premium", meta: meta)) // consumes the id
        do {
            _ = try await handler(CallTool.Parameters(name: "premium", meta: meta))
            Issue.record("expected a replay rejection")
        } catch {
            guard let (code, data) = paymentRequired(error) else {
                Issue.record("expected .paymentRequired, got \(error)"); return
            }
            #expect(code == MCPPayment.verificationFailedCode)
            let problem = try MCPPaymentCodec.problem(fromErrorData: data)
            #expect(problem != nil)
            #expect(problem?.extensions["challengeId"] != nil)
        }
    }

    @Test("attaching the receipt preserves the handler's existing _meta and content")
    func receiptPreservesExistingMeta() async throws {
        let existing = Metadata(additionalFields: ["existingKey": .string("value")])
        let handler = try mcpGate(okHandler(meta: existing))
        let result = try await handler(
            CallTool.Parameters(name: "premium", meta: mcpCredentialMeta())
        )
        #expect(result._meta?["existingKey"] == .string("value"))
        #expect(result._meta?[MCPPayment.receiptMetaKey] != nil)
        if case let .text(text, _, _) = result.content.first {
            #expect(text == "ok")
        } else {
            Issue.record("expected the handler's content to be preserved")
        }
    }
}

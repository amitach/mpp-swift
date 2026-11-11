import MCP
import MPPCore
import MPPServer
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
        let pair = try await makePreservedPaymentPair(clientMethods: [mcpProofMethod()])
        let paid = try await pair.client.callTool(name: "premium")

        #expect(paid.result.isError != true)
        let receipt = try #require(paid.receipt)
        #expect(receipt.method.rawValue == "tempo")
        // The receipt's challenge id is the challenge the server offered, not merely equal
        // to the receipt's own reference.
        let offered = Receipt.ReceiptValue.string(pair.challengeID)
        #expect(receipt.extras[MCPPaymentCodec.challengeIDKey] == offered)
        #expect(receipt.reference == pair.challengeID)
        if case let .text(text, _, _) = paid.result.content.first {
            #expect(text.contains("premium content"))
        } else {
            Issue.record("expected text content, got \(paid.result.content)")
        }
    }

    @Test("a client with no supporting method surfaces the original preserved payment error")
    func noSupportingMethod() async throws {
        let payClient = try await makePreservedPaymentPair(clientMethods: []).client
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

    @Test("spec-correct absent credential -32042 is not payable")
    func specCorrectAbsentCredentialIsNotPayable() async throws {
        // specCorrect still emits -32042 when no credential was supplied. The SDK drops
        // data.challenges on that code, same as the peer-compatible gate.
        let payClient = try await makeMCPPaymentPair(
            clientMethods: [mcpProofMethod()],
            codeMode: .specCorrect
        )
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

    @Test("a rejected paid retry propagates and is not retried")
    func replayRejected() async throws {
        let calls = CallCounter()
        let gate = try mcpGate { _ in
            CallTool.Result(content: [
                .text(text: "premium content", annotations: nil, _meta: nil),
            ])
        }
        let challenge = try ChallengeMinter(signer: ChallengeSigner(secret: mcpSecret)).mint(
            binding: RouteBinding(realm: mcpRealm, method: MethodName("tempo"), intent: .charge),
            request: mcpChargeRequest(),
            expires: Expires(date: mcpNow.addingTimeInterval(3600))
        )
        let data = try MCPPaymentCodec.errorData(challenges: [challenge], problem: nil)
        let payClient = try await makeMCPPair(clientMethods: [mcpProofMethod()]) { params in
            await calls.bump()
            if params._meta?[MCPPayment.credentialMetaKey] != nil {
                return try await gate(params)
            }
            throw MCPError.serverErrorWithData(
                code: MCPPayment.verificationFailedCode,
                message: "Payment Required",
                data: .object(data)
            )
        }
        _ = try await payClient.callTool(name: "premium")
        let afterFirst = await calls.count
        do {
            _ = try await payClient.callTool(name: "premium")
            Issue.record("expected the replay rejection to propagate")
        } catch let error as MCPError {
            // The peer-compatible gate emits -32042 for the rejected credential. The SDK
            // decodes that as URL elicitation. The call still fails, and it is not paid again.
            guard case .urlElicitationRequired = error else {
                Issue.record("expected .urlElicitationRequired, got \(error)"); return
            }
            #expect(error.code == MCPPayment.paymentRequiredCode)
        }
        // One fresh challenge plus one rejected retry. A further retry would bump again.
        #expect(await calls.count - afterFirst == 2)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func bump() {
        count += 1
    }
}

import Foundation
import MCP
import MPPClient
import Testing
@testable import MPPMCP

// The MCP client pays a -32042 challenge through the SAME buildCredential chokepoint as the
// HTTP flow, so the PaymentAuthorizer seam covers it identically: a denial short-circuits the
// payment (no credential built, no paid retry) and propagates unwrapped.

enum MCPAuthorizerTestError: Error, Equatable { case denied }

private struct MCPDenyingAuthorizer: PaymentAuthorizer {
    func authorize(_: PaymentApprovalRequest) async throws {
        throw MCPAuthorizerTestError.denied
    }
}

@Suite("MCP payment client authorizer")
struct MCPPaymentClientAuthorizerTests {
    @Test("a denied payment throws unwrapped and is not retried")
    func denyShortCircuits() async throws {
        let payClient = try await makeMCPPaymentPair(
            clientMethods: [mcpProofMethod()],
            authorizer: MCPDenyingAuthorizer()
        )
        await #expect(throws: MCPAuthorizerTestError.denied) {
            _ = try await payClient.callTool(name: "premium")
        }
    }

    @Test("an allow-all authorizer pays exactly as the ungated client did")
    func allowAllPays() async throws {
        let payClient = try await makeMCPPaymentPair(
            clientMethods: [mcpProofMethod()],
            authorizer: AllowAllAuthorizer()
        )
        let paid = try await payClient.callTool(name: "premium")
        #expect(paid.receipt != nil)
    }
}

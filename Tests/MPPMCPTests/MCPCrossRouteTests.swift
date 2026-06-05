import Foundation
import MCP
import MPPCore
import MPPServer
import MPPTempo
import Testing
@testable import MPPMCP

// MCP-XROUTE (audit pin): a credential minted for one route's binding, presented to a gate for a
// different binding under the same shared secret, is rejected -- the confused-deputy / cross-route
// replay guard. The verifier pins the echoed challenge's (realm, method, intent) to the gate's
// expected binding, so a valid HMAC for the wrong route does not authorize the call.
@Suite("MCP cross-route binding (MCP-XROUTE)")
struct MCPCrossRouteTests {
    private func okHandler() -> @Sendable (CallTool.Parameters) async throws -> CallTool.Result {
        { _ in CallTool.Result(
            content: [.text(text: "ok", annotations: nil, _meta: nil)],
            _meta: nil
        ) }
    }

    /// The `_meta` a client would send: a real proof credential minted for `realm` (same secret).
    private func meta(forRealm realm: String) async throws -> Metadata {
        let challenge = try ChallengeMinter(signer: ChallengeSigner(secret: mcpSecret)).mint(
            binding: RouteBinding(realm: realm, method: MethodName("tempo"), intent: .charge),
            request: mcpChargeRequest(),
            expires: Expires(date: mcpNow.addingTimeInterval(3600))
        )
        let credential = try await mcpProofMethod().buildCredential(for: challenge)
        return try Metadata(additionalFields: [
            MCPPayment.credentialMetaKey: MCPPaymentCodec.value(for: credential),
        ])
    }

    private func isPaymentRequired(_ error: Error) -> Bool {
        if let mcp = error as? MCPError, case .paymentRequired = mcp { return true }
        return false
    }

    @Test("a credential minted for a different realm is rejected, not honored")
    func crossRealmCredentialRejected() async throws {
        let gate = try mcpGate(okHandler())
        // Sanity: a credential for the gate's own realm proceeds.
        let result = try await gate(CallTool.Parameters(name: "premium", meta: mcpCredentialMeta()))
        #expect(!result.content.isEmpty)
        // The same proof minted for a different realm fails the binding pin -> re-challenge.
        let wrongMeta = try await meta(forRealm: "https://evil.example.com")
        do {
            _ = try await gate(CallTool.Parameters(name: "premium", meta: wrongMeta))
            Issue.record("expected paymentRequired for a cross-route credential")
        } catch {
            #expect(isPaymentRequired(error))
        }
    }
}

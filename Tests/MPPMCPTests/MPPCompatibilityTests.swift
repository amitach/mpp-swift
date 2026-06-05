import MPPCore
import MPPMCP
import Testing

// B9: the MCP error-code mode derived from a compatibility profile. MCPErrorCodeMode is
// Sendable-only (not Equatable), so match by case.
@Suite("MPPCompatibility profile (MCP switch)")
struct MPPCompatibilityMCPTests {
    private func isPeerCompatible(_ mode: MCPErrorCodeMode) -> Bool {
        if case .peerCompatible = mode { true } else { false }
    }

    @Test("mppx maps to peerCompatible; specCorrect maps to the spec codes")
    func codeMode() {
        #expect(isPeerCompatible(MCPErrorCodeMode(.mppx)))
        #expect(!isPeerCompatible(MCPErrorCodeMode(.specCorrect)))
    }
}

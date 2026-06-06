import MPPCore
import MPPMCP
import Testing

// B9: the MCP error-code mode derived from a compatibility profile.
@Suite("MPPCompatibility profile (MCP switch)")
struct MPPCompatibilityMCPTests {
    @Test("mppx maps to peerCompatible; specCorrect maps to the spec codes")
    func codeMode() {
        #expect(MCPErrorCodeMode(.mppx) == .peerCompatible)
        #expect(MCPErrorCodeMode(.specCorrect) == .specCorrect)
    }
}

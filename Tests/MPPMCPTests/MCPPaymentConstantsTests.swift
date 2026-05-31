import Testing
@testable import MPPMCP

@Suite("MCP payment constants")
struct MCPPaymentConstantsTests {
    @Test("wire constants match the transport binding spec")
    func constants() {
        #expect(MCPPayment.paymentRequiredCode == -32042)
        #expect(MCPPayment.verificationFailedCode == -32043)
        #expect(MCPPayment.credentialMetaKey == "org.paymentauth/credential")
        #expect(MCPPayment.receiptMetaKey == "org.paymentauth/receipt")
    }
}

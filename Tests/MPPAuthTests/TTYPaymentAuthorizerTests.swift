import Foundation
import MPPAuth
import MPPClient
import MPPCore
import Testing

// The terminal authorizer approves only on an explicit y / yes and denies everything else,
// including end-of-input. Both ends are injected, so this runs on every platform.

private func approvalRequest(
    amount: Amount?,
    currency: String? = "usd",
    recipient: String? = "acct_x"
) throws -> PaymentApprovalRequest {
    try PaymentApprovalRequest(
        challengeId: "c", realm: "api.example.com",
        method: MethodName("stripe"), intent: .charge,
        amount: amount, currency: currency, recipient: recipient,
        description: nil, expires: nil
    )
}

private final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    func append(_ text: String) {
        lock.lock(); stored += text; lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

@Suite("TTYPaymentAuthorizer")
struct TTYPaymentAuthorizerTests {
    @Test("an explicit y approves, and the prompt names the amount and payee")
    func approvesOnYes() async throws {
        let box = PromptBox()
        let auth = TTYPaymentAuthorizer(promptSink: { box.append($0) }, readResponse: { "y" })
        try await auth.authorize(approvalRequest(amount: Amount("1000")))
        #expect(box.text.contains("1000"))
        #expect(box.text.contains("acct_x"))
    }

    @Test("yes in any case, padded with whitespace, approves")
    func approvesOnPaddedYes() async throws {
        let auth = TTYPaymentAuthorizer(promptSink: { _ in }, readResponse: { "  YES  " })
        try await auth.authorize(approvalRequest(amount: Amount("1000")))
    }

    @Test("a no answer denies")
    func deniesOnNo() async throws {
        let auth = TTYPaymentAuthorizer(promptSink: { _ in }, readResponse: { "n" })
        let req = try approvalRequest(amount: Amount("1000"))
        await #expect(throws: PaymentDenied.declined) { try await auth.authorize(req) }
    }

    @Test("end of input (nil) denies, never approves by default")
    func deniesOnEndOfInput() async throws {
        let auth = TTYPaymentAuthorizer(promptSink: { _ in }, readResponse: { nil })
        let req = try approvalRequest(amount: Amount("1000"))
        await #expect(throws: PaymentDenied.declined) { try await auth.authorize(req) }
    }
}

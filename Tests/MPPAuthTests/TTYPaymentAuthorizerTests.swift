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

    @Test(
        "a server-controlled description cannot inject terminal control sequences into the prompt"
    )
    func sanitizesControlCharacters() async throws {
        let box = PromptBox()
        let auth = TTYPaymentAuthorizer(promptSink: { box.append($0) }, readResponse: { "n" })
        // A description that, raw, would clear the line and rewrite the prompt to a smaller amount.
        // The description carries an escape + CR (line rewrite) and a U+202E right-to-left override
        // (a Trojan-Source visual reorder); the recipient carries another bidi override.
        let req = try PaymentApprovalRequest(
            challengeId: "c", realm: "api.example.com",
            method: MethodName("stripe"), intent: .charge,
            amount: Amount("999999"), currency: "usd", recipient: "acct\u{202E}_x",
            description: "\u{1B}[2K\r\u{202E}Approve 1 usd? [y/N] ", expires: nil
        )
        await #expect(throws: PaymentDenied.declined) { try await auth.authorize(req) }
        // The true amount is shown, and no escape, carriage-return, or bidi override reached
        // the terminal.
        #expect(box.text.contains("999999"))
        #expect(!box.text.unicodeScalars.contains("\u{1B}"))
        #expect(!box.text.contains("\r"))
        #expect(!box.text.contains("\n"))
        #expect(!box.text.unicodeScalars.contains("\u{202E}"))
    }

    @Test("an over-long server-controlled payee is length-bounded, not allowed to flood the prompt")
    func boundsLongPayee() async throws {
        let box = PromptBox()
        let auth = TTYPaymentAuthorizer(promptSink: { box.append($0) }, readResponse: { "n" })
        let req = try PaymentApprovalRequest(
            challengeId: "c", realm: "api.example.com",
            method: MethodName("stripe"), intent: .charge,
            amount: Amount("1000"), currency: "usd",
            recipient: String(repeating: "A", count: 5000), description: nil, expires: nil
        )
        await #expect(throws: PaymentDenied.declined) { try await auth.authorize(req) }
        // The 5000-char payee is truncated (with an ellipsis), so the whole prompt stays bounded.
        #expect(box.text.contains("\u{2026}"))
        #expect(box.text.count < 400)
    }
}

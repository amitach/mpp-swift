import MPPCore
import Testing
@testable import MPPClient

@Suite("BudgetAuthorizer")
struct BudgetAuthorizerTests {
    private func request(
        _ amount: String,
        currency: String? = nil
    ) throws -> PaymentApprovalRequest {
        try PaymentApprovalRequest(
            challengeId: "c1", realm: "api.example.com", method: MethodName("tempo"),
            intent: .charge, amount: Amount(amount), currency: currency,
            recipient: nil, description: nil, expires: nil
        )
    }

    private func isDenied(_ error: any Error, _ match: (PaymentDenied) -> Bool) -> Bool {
        (error as? PaymentDenied).map(match) ?? false
    }

    @Test("an approved spend debits the remaining budget")
    func debits() async throws {
        let authorizer = try BudgetAuthorizer(budget: Amount("100"))
        try await authorizer.authorize(request("30"))
        #expect(try await authorizer.remaining == Amount("70"))
        try await authorizer.authorize(request("70"))
        #expect(try await authorizer.remaining == Amount("0"))
    }

    @Test("a spend over the remaining budget is denied and leaves the budget unchanged")
    func overBudget() async throws {
        let authorizer = try BudgetAuthorizer(budget: Amount("100"))
        try await authorizer.authorize(request("60"))
        await #expect(throws: PaymentDenied.self) { try await authorizer.authorize(request("60")) }
        #expect(try await authorizer.remaining == Amount("40"))
    }

    @Test("an unknown amount fails closed")
    func amountUnknown() async throws {
        let authorizer = try BudgetAuthorizer(budget: Amount("100"))
        let req = try PaymentApprovalRequest(
            challengeId: "c1", realm: "r", method: MethodName("tempo"), intent: .charge,
            amount: nil, currency: nil, recipient: nil, description: nil, expires: nil
        )
        do {
            try await authorizer.authorize(req)
            Issue.record("expected denial")
        } catch {
            #expect(isDenied(error) { if case .amountUnknown = $0 { true } else { false } })
        }
    }

    @Test("a pinned currency denies a mismatched charge (case-insensitive)")
    func currencyPin() async throws {
        let authorizer = try BudgetAuthorizer(budget: Amount("100"), currency: "USD")
        try await authorizer.authorize(request("10", currency: "usd")) // case-insensitive match
        do {
            try await authorizer.authorize(request("10", currency: "eur"))
            Issue.record("expected denial")
        } catch {
            #expect(isDenied(error) { if case .currencyMismatch = $0 { true } else { false } })
        }
    }

    @Test("topUp adds to the remaining budget (a recharge)")
    func topUp() async throws {
        let authorizer = try BudgetAuthorizer(budget: Amount("100"))
        try await authorizer.authorize(request("90"))
        try await authorizer.topUp(Amount("50"))
        #expect(try await authorizer.remaining == Amount("60"))
    }

    @Test("concurrent authorizes never overspend the budget (atomic check-and-debit)")
    func atomicNoOverspend() async throws {
        let authorizer = try BudgetAuthorizer(budget: Amount("100"))
        let spend = try request("20")
        let approved = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    do { try await authorizer.authorize(spend); return true } catch { return false }
                }
            }
            var count = 0
            for await succeeded in group where succeeded {
                count += 1
            }
            return count
        }
        #expect(approved == 5) // exactly 100 / 20, never 6
        #expect(try await authorizer.remaining == Amount("0"))
    }
}

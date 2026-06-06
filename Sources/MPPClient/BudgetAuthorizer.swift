import MPPCore

/// A stateful ``PaymentAuthorizer`` that approves spends against a **running budget**, debiting it
/// atomically per call, and supports a top-up (a recharge).
///
/// This is the budget half of a prepaid model: set a budget, and every approved payment draws it
/// down; once it is exhausted, further spends are denied (``PaymentDenied/overCap(amount:cap:)``
/// where `cap` is the remaining budget). It **fails closed** like ``SpendingCapAuthorizer``: an
/// unknown amount is denied, and an optional currency pin denies a mismatched (or absent) currency.
///
/// - Important: it is an `actor` precisely so the check-and-debit is **atomic**. The 402 flow may
///   run many payments concurrently; a non-atomic budget would let two in-flight spends both pass
///   the check before either is recorded and overspend (a time-of-check/time-of-use race). The
///   actor serializes `authorize(_:)`, and the body has no suspension point between the budget
///   check and the debit, so exactly the approved set is admitted.
///
/// Rail-agnostic: it reasons only over the ``Amount`` and currency the rail decoded into the
/// approval request. The in-memory state also makes it a local stand-in for a hosted ledger's
/// balance during development; a production ledger implements ``PaymentAuthorizer`` over its own
/// durable, transactional store.
public actor BudgetAuthorizer: PaymentAuthorizer {
    /// The budget remaining, in base units.
    public private(set) var remaining: Amount
    /// The currency the budget is denominated in. When set, a charge in another currency (or with
    /// no currency) is denied; the match is case-insensitive. When `nil`, the budget applies to the
    /// amount regardless of currency.
    public let currency: String?

    /// Creates a budget of `budget`, optionally pinned to `currency`.
    public init(budget: Amount, currency: String? = nil) {
        remaining = budget
        self.currency = currency
    }

    /// Approves `request` when its amount is known, in the pinned currency (if any), and within the
    /// remaining budget; on approval the budget is debited by the amount. Throws ``PaymentDenied``
    /// otherwise, leaving the budget unchanged.
    public func authorize(_ request: PaymentApprovalRequest) async throws {
        guard let amount = request.amount else { throw PaymentDenied.amountUnknown }
        if let currency, currency.lowercased() != request.currency?.lowercased() {
            throw PaymentDenied.currencyMismatch(expected: currency, got: request.currency)
        }
        guard amount <= remaining else {
            throw PaymentDenied.overCap(amount: amount, cap: remaining)
        }
        // No `await` between the check above and this debit, so the actor admits exactly the
        // approved set even under concurrent calls. `amount <= remaining`, so the difference is a
        // canonical non-negative integer and `Amount(_:)` succeeds. If it somehow did not, fail
        // CLOSED -- deny the spend and leave the budget unchanged -- rather than approve a payment
        // without debiting it (which would let the budget be overspent).
        guard let debited = try? Amount(Self.subtract(remaining.rawValue, amount.rawValue)) else {
            throw PaymentDenied.overCap(amount: amount, cap: remaining)
        }
        remaining = debited
    }

    /// Adds `amount` to the remaining budget (a recharge / top-up).
    public func topUp(_ amount: Amount) {
        remaining = (try? Amount(Self.add(remaining.rawValue, amount.rawValue))) ?? remaining
    }

    // MARK: - Decimal arithmetic over canonical non-negative base-units strings

    /// `lhs + rhs` for two canonical non-negative integer decimal strings.
    private static func add(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.reversed().map { $0.wholeNumberValue ?? 0 }
        let right = rhs.reversed().map { $0.wholeNumberValue ?? 0 }
        var digits: [Int] = []
        var carry = 0
        for index in 0 ..< max(left.count, right.count) {
            let sum = (index < left.count ? left[index] : 0)
                + (index < right.count ? right[index] : 0) + carry
            digits.append(sum % 10)
            carry = sum / 10
        }
        if carry > 0 { digits.append(carry) }
        return String(digits.reversed().map { Character(String($0)) })
    }

    /// `lhs - rhs` for canonical non-negative integers with `lhs >= rhs` (the only case the debit
    /// path uses, guarded by `amount <= remaining`). Strips leading zeros to stay canonical.
    private static func subtract(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.reversed().map { $0.wholeNumberValue ?? 0 }
        let right = rhs.reversed().map { $0.wholeNumberValue ?? 0 }
        var digits: [Int] = []
        var borrow = 0
        for index in 0 ..< left.count {
            var diff = left[index] - borrow - (index < right.count ? right[index] : 0)
            if diff < 0 {
                diff += 10
                borrow = 1
            } else {
                borrow = 0
            }
            digits.append(diff)
        }
        var result = Array(digits.reversed())
        while result.count > 1, result.first == 0 {
            result.removeFirst()
        }
        return String(result.map { Character(String($0)) })
    }
}

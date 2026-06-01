import MPPCore

/// A ``PaymentAuthorizer`` that approves a spend only when its amount is within a
/// fixed cap (and, optionally, in an expected currency).
///
/// The unattended guardrail: it makes no network call and prompts no one, so it
/// suits headless / CI runs where a cap should bound autonomous spend. It **fails
/// closed**: a request with no `amount` is denied (``PaymentDenied/amountUnknown``)
/// rather than treated as free, and a currency mismatch is denied. A larger,
/// stateful policy (per-task budgets, velocity limits, step-up prompts) is a
/// consumer concern that composes this with its own authorizer.
public struct SpendingCapAuthorizer: PaymentAuthorizer {
    /// The maximum approved amount, in base units.
    public let maxAmount: Amount
    /// The currency the cap is denominated in. When set, a charge in another
    /// currency (or with no currency) is denied; when `nil`, the cap applies to
    /// the amount regardless of currency. The match is case-insensitive (`usd` ==
    /// `USD`, a lowercase == checksummed EVM address).
    public let currency: String?

    /// Creates a cap of `maxAmount`, optionally pinned to `currency`.
    public init(maxAmount: Amount, currency: String? = nil) {
        self.maxAmount = maxAmount
        self.currency = currency
    }

    /// Approves `request` when its amount is known, within the cap, and (if the
    /// cap is currency-pinned) in the expected currency; throws ``PaymentDenied``
    /// otherwise.
    public func authorize(_ request: PaymentApprovalRequest) async throws {
        guard let amount = request.amount else { throw PaymentDenied.amountUnknown }
        // Compare case-insensitively: a fiat code (`usd` vs `USD`) and an EVM address (checksummed
        // vs lowercase) are the same currency, and rails surface them in different cases. A missing
        // charge currency still fails closed (it never equals the pinned currency).
        if let currency, currency.lowercased() != request.currency?.lowercased() {
            throw PaymentDenied.currencyMismatch(expected: currency, got: request.currency)
        }
        guard amount <= maxAmount else {
            throw PaymentDenied.overCap(amount: amount, cap: maxAmount)
        }
    }
}

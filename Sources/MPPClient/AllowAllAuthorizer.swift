/// A ``PaymentAuthorizer`` that approves every spend.
///
/// The ungated default: a client constructed without an authorizer behaves
/// exactly as one constructed with this. It is also the headless / CI path,
/// where keys come from the environment and there is no human to prompt; pair it
/// with a ``SpendingCapAuthorizer`` for an unattended guardrail.
public struct AllowAllAuthorizer: PaymentAuthorizer {
    /// Creates the authorizer.
    public init() {}

    /// Approves `request` unconditionally (never throws).
    public func authorize(_: PaymentApprovalRequest) async throws {}
}

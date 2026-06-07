import MPPClient

/// A pre-sign spending gate for ``X402ChargeMethod``: the vendor-neutral ``PaymentApprovalRequest``
/// (amount / currency / recipient) is surfaced to it **before any EIP-3009 authorization is
/// signed**,
/// so a real-money charge can be refused without ever producing a signature.
///
/// This is the rail-level counterpart to ``TempoApprovalPolicy`` and is complementary to the flow's
/// ``PaymentAuthorizer`` (the ``PaymentClient`` also gates via
/// ``X402ChargeMethod/approvalFacts(for:)``):
/// the policy here is an in-method, opt-in safety belt for the x402 rail specifically. The default
/// ``allowAll`` signs every charge (delegating the decision to the flow authorizer); a caller can
/// substitute a spending cap or a user prompt.
public struct X402ApprovalPolicy: Sendable {
    private let decide: @Sendable (PaymentApprovalRequest) async -> Bool

    /// Creates a policy from a decision function over the charge's approval facts.
    public init(_ decide: @escaping @Sendable (PaymentApprovalRequest) async -> Bool) {
        self.decide = decide
    }

    /// Whether the charge described by `request` may be signed.
    public func approves(_ request: PaymentApprovalRequest) async -> Bool {
        await decide(request)
    }

    /// Signs every charge -- the gate is left entirely to the flow's ``PaymentAuthorizer``.
    public static let allowAll = X402ApprovalPolicy { _ in true }

    /// Refuses every charge (useful for tests and a hard kill-switch).
    public static let deny = X402ApprovalPolicy { _ in false }
}

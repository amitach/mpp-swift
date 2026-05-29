import MPPCore

/// The facts about a charge a client sees before deciding whether to pay it,
/// surfaced to a ``TempoApprovalPolicy`` before any signature is produced.
///
/// These are the spending-control fields: the protection-space `realm`, the
/// `amount` in base units, the `currency`/token and `recipient` of a settled
/// transfer (both absent for a bare zero-amount proof), and the `validUntil`
/// deadline carried by the challenge. The policy reads these to approve or
/// reject; it never sees signing material.
public struct ChargeApproval: Sendable, Hashable {
    /// The protection-space identifier the charge is scoped to.
    public let realm: String
    /// The charge amount in base units (`"0"` for a zero-amount proof).
    public let amount: Amount
    /// The token/currency address of a settled transfer, if any.
    public let currency: String?
    /// The payee address of a settled transfer, if any.
    public let recipient: String?
    /// The challenge's expiry deadline, if it set one.
    public let validUntil: Expires?

    /// Creates the approval facts surfaced to a policy.
    public init(
        realm: String,
        amount: Amount,
        currency: String?,
        recipient: String?,
        validUntil: Expires?
    ) {
        self.realm = realm
        self.amount = amount
        self.currency = currency
        self.recipient = recipient
        self.validUntil = validUntil
    }
}

/// A pre-sign spending control: the method calls it with the ``ChargeApproval``
/// facts and signs only if it returns `true`. The decision runs before any
/// credential is built, so a rejected charge produces no signature at all.
///
/// The decision is `async` so a policy may consult the user or an external
/// service. The default ``allowAll`` signs every charge (matching an
/// ungated client); supply a real policy whenever real funds are at stake.
public struct TempoApprovalPolicy: Sendable {
    private let decide: @Sendable (ChargeApproval) async -> Bool

    /// Wraps a decision function.
    public init(_ decide: @escaping @Sendable (ChargeApproval) async -> Bool) {
        self.decide = decide
    }

    /// Whether `charge` may be paid.
    public func approves(_ charge: ChargeApproval) async -> Bool {
        await decide(charge)
    }

    /// Approves every charge. The ungated default; replace it for real funds.
    public static let allowAll = TempoApprovalPolicy { _ in true }

    /// Rejects every charge.
    public static let deny = TempoApprovalPolicy { _ in false }
}

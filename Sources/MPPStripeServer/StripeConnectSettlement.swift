import MPPStripe

/// A Stripe Connect transfer: the destination connected account and an optional explicit amount.
/// `destination` is required by the type (so a "missing destination" is unrepresentable, a
/// compile-time guarantee the reference SDK enforces only at runtime).
public struct StripeTransferData: Sendable, Hashable {
    /// The connected account the funds are transferred to (must be non-empty).
    public let destination: String
    /// The amount transferred to `destination`, in the charge currency's smallest unit. When
    /// omitted, Stripe transfers the full charge (less any application fee).
    public let amount: Int?

    public init(destination: String, amount: Int? = nil) {
        self.destination = destination
        self.amount = amount
    }
}

/// Server-configured Stripe Connect settlement for a charge. It is never client-supplied or carried
/// in the MPP challenge; a charging server sets it (statically or via a resolver) to route funds to
/// a connected account, take a platform fee, or set a transfer group. All fields are optional;
/// `nil` everywhere means a plain (non-Connect) charge.
public struct StripeConnectSettlement: Sendable, Hashable {
    /// The platform application fee, in the charge currency's smallest unit (0...charge amount).
    public let applicationFeeAmount: Int?
    /// The connected account that is the business of record for the charge (non-empty when set).
    public let onBehalfOf: String?
    /// The transfer to a connected account, if any.
    public let transferData: StripeTransferData?
    /// A reconciliation token grouping related transfers.
    public let transferGroup: String?
    /// The connected account the PaymentIntent is created on (the `Stripe-Account` header).
    /// Non-empty
    /// when set.
    public let stripeAccount: String?

    public init(
        applicationFeeAmount: Int? = nil,
        onBehalfOf: String? = nil,
        transferData: StripeTransferData? = nil,
        transferGroup: String? = nil,
        stripeAccount: String? = nil
    ) {
        self.applicationFeeAmount = applicationFeeAmount
        self.onBehalfOf = onBehalfOf
        self.transferData = transferData
        self.transferGroup = transferGroup
        self.stripeAccount = stripeAccount
    }
}

/// The specific Connect-settlement rule a settlement violated, validated before any PaymentIntent
/// is created (so an invalid settlement never reaches Stripe).
public enum StripeConnectViolation: Error, Sendable, Hashable {
    /// `stripeAccount` was set but empty.
    case emptyStripeAccount
    /// `onBehalfOf` was set but empty.
    case emptyOnBehalfOf
    /// `applicationFeeAmount` was negative.
    case applicationFeeNegative
    /// `applicationFeeAmount` exceeded the charge amount.
    case applicationFeeExceedsAmount
    /// `transferData.destination` was empty.
    case emptyTransferDestination
    /// `transferData.amount` was negative.
    case transferAmountNegative
    /// `transferData.amount` exceeded the charge amount.
    case transferAmountExceedsAmount

    /// Validates `settlement` against `amount` (the PaymentIntent amount, a non-negative integer),
    /// returning the violated rule or `nil` if valid (or no settlement). Mirrors the reference
    /// SDK's `validateConnectSettlement` rule set.
    static func violation(
        in settlement: StripeConnectSettlement?, amount: Int
    ) -> StripeConnectViolation? {
        guard let settlement else { return nil }
        if let account = settlement.stripeAccount, account.isEmpty { return .emptyStripeAccount }
        if let onBehalfOf = settlement.onBehalfOf, onBehalfOf.isEmpty { return .emptyOnBehalfOf }
        if let fee = settlement.applicationFeeAmount,
           let violation = boundedFee(
               fee,
               max: amount,
               negative: .applicationFeeNegative,
               exceeds: .applicationFeeExceedsAmount
           ) {
            return violation
        }
        return transferViolation(settlement.transferData, amount: amount)
    }

    private static func transferViolation(
        _ transfer: StripeTransferData?, amount: Int
    ) -> StripeConnectViolation? {
        guard let transfer else { return nil }
        if transfer.destination.isEmpty { return .emptyTransferDestination }
        if let transferAmount = transfer.amount {
            return boundedFee(
                transferAmount,
                max: amount,
                negative: .transferAmountNegative,
                exceeds: .transferAmountExceedsAmount
            )
        }
        return nil
    }

    /// A non-negative amount that must not exceed `max`; returns the matching violation or nil.
    private static func boundedFee(
        _ value: Int, max: Int,
        negative: StripeConnectViolation, exceeds: StripeConnectViolation
    ) -> StripeConnectViolation? {
        if value < 0 { return negative }
        if value > max { return exceeds }
        return nil
    }
}

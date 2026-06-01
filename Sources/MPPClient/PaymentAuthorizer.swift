import MPPCore

/// The vendor-neutral facts a client weighs before paying a selected challenge,
/// surfaced to a ``PaymentAuthorizer`` before any credential is built.
///
/// These are the consent-relevant fields knowable from the challenge alone, plus
/// the `amount`/`currency`/`recipient` a rail can decode from the challenge's
/// method-specific `request` (see ``PaymentMethodClient/approvalFacts(for:)``).
/// They carry no signing material and no payment instrument: this is the
/// "approve this spend?" surface, not the credential. `amount`/`currency`/
/// `recipient` are optional because a rail that cannot decode them (or a generic
/// caller) leaves them absent; an authorizer that needs an amount must fail
/// closed when it is `nil` rather than treat the spend as free.
public struct PaymentApprovalRequest: Sendable, Hashable {
    /// The identifier of the challenge being paid.
    public let challengeId: String
    /// The protection-space identifier (the charging server's realm).
    public let realm: String
    /// The payment method (e.g. `tempo`, `stripe`).
    public let method: MethodName
    /// The payment intent (e.g. `charge`, `subscription`, `session`).
    public let intent: IntentName
    /// The charge amount in base units, if the rail decoded it. `nil` when unknown.
    public let amount: Amount?
    /// The currency or token of the charge, if the rail decoded it. The form is
    /// rail-defined: a fiat code for Stripe (e.g. `"usd"`), a token address for
    /// Tempo. EVM addresses are case-insensitive and a rail may surface them
    /// lowercased or EIP-55 checksummed, so an authorizer that matches on a token
    /// should normalize case rather than compare raw strings.
    public let currency: String?
    /// The payee identifier of the charge, if the rail decoded it. Rail-defined,
    /// and for EVM rails an address whose case an authorizer should normalize
    /// (see ``currency``).
    public let recipient: String?
    /// The challenge's human-readable description, for display only.
    public let description: String?
    /// The challenge's expiry deadline, if it set one.
    public let expires: Expires?

    /// Creates an approval request from its fields.
    public init(
        challengeId: String,
        realm: String,
        method: MethodName,
        intent: IntentName,
        amount: Amount?,
        currency: String?,
        recipient: String?,
        description: String?,
        expires: Expires?
    ) {
        self.challengeId = challengeId
        self.realm = realm
        self.method = method
        self.intent = intent
        self.amount = amount
        self.currency = currency
        self.recipient = recipient
        self.description = description
        self.expires = expires
    }

    /// The rail-agnostic facts available on `challenge` alone: amount, currency,
    /// and recipient are left `nil` (they live in the method-specific `request`,
    /// which only the rail can decode). The default
    /// ``PaymentMethodClient/approvalFacts(for:)`` returns this; a rail overrides
    /// it to fill the decoded fields.
    public init(generic challenge: Challenge) {
        self.init(
            challengeId: challenge.id,
            realm: challenge.realm,
            method: challenge.method,
            intent: challenge.intent,
            amount: nil,
            currency: nil,
            recipient: nil,
            description: challenge.description,
            expires: challenge.expires
        )
    }
}

/// Decides whether a selected payment may proceed, before the credential is built.
///
/// The 402 client flow consults the authorizer once, after it has selected the
/// challenge to pay and before the method signs anything or mints any payment
/// instrument. Returning approves the spend; throwing denies it, and no credential
/// is built (the thrown error propagates to the caller unwrapped, like a method
/// error). The decision is `async` so an implementation may prompt the user
/// (a biometric or terminal confirmation) or consult an external policy.
///
/// The default ``AllowAllAuthorizer`` approves every spend, preserving the
/// behavior of a client constructed without one; supply a real authorizer
/// (a spending cap, a user prompt) whenever real funds are at stake.
public protocol PaymentAuthorizer: Sendable {
    /// Approves `request`, or throws to deny it (no credential is then built).
    func authorize(_ request: PaymentApprovalRequest) async throws
}

/// A reason a ``PaymentAuthorizer`` denied a spend.
///
/// These are the rejections the built-in authorizers raise. A custom authorizer
/// may throw any error; the flow propagates it unwrapped.
public enum PaymentDenied: Error, Sendable, Hashable {
    /// The request carried no `amount`, so a cap could not be applied; the
    /// authorizer fails closed rather than treat an unknown amount as free.
    case amountUnknown
    /// The charge `amount` exceeded the authorizer's cap.
    case overCap(amount: Amount, cap: Amount)
    /// The charge `currency` did not match the currency the cap is denominated in.
    case currencyMismatch(expected: String, got: String?)
}

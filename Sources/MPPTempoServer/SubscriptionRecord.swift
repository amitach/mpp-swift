import Foundation
import MPPCore
import MPPEVM

/// The server's record of an active Tempo subscription: the signed key
/// authorization the payer granted, the immutable economic terms, the charging
/// progress, and the in-flight-renewal claim.
///
/// A subscription bills in fixed periods from its ``billingAnchor``: the period
/// index due as of a time is ``duePeriod(at:)``, and the server advances
/// ``lastChargedPeriod`` as each period is charged. The recurring charge is made
/// by the server using ``keyAuthorization`` (the access key the payer delegated),
/// which caps each period's charge at ``amount`` on ``currency`` to ``recipient``
/// until ``expiry``. The ``inFlight`` claim is how concurrent renewers agree on a
/// single charge per period (the atomic two-phase commit in ``SubscriptionEngine``).
public struct SubscriptionRecord: Sendable, Hashable {
    /// The immutable subscription identity.
    public var subscriptionID: String
    /// The caller-facing key the active subscription for a customer/plan is found
    /// by; a new subscription for the same key supersedes the old (see
    /// ``SubscriptionEngine/activate(_:now:)``).
    public var lookupKey: String
    /// The serialized signed ``TempoKeyAuthorization`` the payer granted at
    /// activation; the server replays it to make each recurring charge.
    public var keyAuthorization: Data
    /// The payer (root) wallet that signed the authorization.
    public var payer: EthereumAddress
    /// The chain the authorization is bound to.
    public var chainID: UInt64

    /// The per-period charge, in base units (the authorization's per-period limit).
    public var amount: Amount
    /// The TIP-20 token the recurring transfer moves.
    public var currency: EthereumAddress
    /// The payee the recurring transfer is scoped to.
    public var recipient: EthereumAddress
    /// The billing period length in whole seconds.
    public var periodSeconds: UInt64
    /// The authorization expiry, in whole Unix seconds; no period is charged at or
    /// after this instant.
    public var expiry: UInt64
    /// An optional caller-defined external id, echoed into renewal references.
    public var externalId: String?

    /// The instant (whole Unix seconds) period 0 began; period boundaries are
    /// measured from here.
    public var billingAnchor: UInt64
    /// The highest period index already charged, or `nil` before the first charge.
    public var lastChargedPeriod: Int?
    /// The reference (a transaction hash) of the most recent charge, if any.
    public var lastReference: String?

    /// The in-flight renewal claim, set while a charge for a period is being made.
    public var inFlight: InFlight?

    /// When the subscription was canceled (by the customer), if it has been.
    public var canceledAt: UInt64?
    /// When the subscription was revoked (by the server), if it has been.
    public var revokedAt: UInt64?

    public init(
        subscriptionID: String,
        lookupKey: String,
        keyAuthorization: Data,
        payer: EthereumAddress,
        chainID: UInt64,
        amount: Amount,
        currency: EthereumAddress,
        recipient: EthereumAddress,
        periodSeconds: UInt64,
        expiry: UInt64,
        billingAnchor: UInt64,
        externalId: String? = nil,
        lastChargedPeriod: Int? = nil,
        lastReference: String? = nil,
        inFlight: InFlight? = nil,
        canceledAt: UInt64? = nil,
        revokedAt: UInt64? = nil
    ) {
        self.subscriptionID = subscriptionID
        self.lookupKey = lookupKey
        self.keyAuthorization = keyAuthorization
        self.payer = payer
        self.chainID = chainID
        self.amount = amount
        self.currency = currency
        self.recipient = recipient
        self.periodSeconds = periodSeconds
        self.expiry = expiry
        self.externalId = externalId
        self.billingAnchor = billingAnchor
        self.lastChargedPeriod = lastChargedPeriod
        self.lastReference = lastReference
        self.inFlight = inFlight
        self.canceledAt = canceledAt
        self.revokedAt = revokedAt
    }

    /// A renewal claim: one renewer stamps it before charging a period, and only
    /// the holder of its ``attempt`` token commits the charge.
    public struct InFlight: Sendable, Hashable {
        /// The period index being charged.
        public var period: Int
        /// The stable idempotency reference for this `(subscription, period)`,
        /// persisted before the charge so a retry reuses it.
        public var reference: String
        /// The ownership token of the renewer that holds the claim.
        public var attempt: String
        /// When the claim was stamped, in whole Unix seconds (for timeout takeover).
        public var startedAt: UInt64

        public init(period: Int, reference: String, attempt: String, startedAt: UInt64) {
            self.period = period
            self.reference = reference
            self.attempt = attempt
            self.startedAt = startedAt
        }
    }

    /// Whether the subscription is chargeable as of `now`: not canceled, not
    /// revoked, and before its expiry.
    public func isActive(at now: UInt64) -> Bool {
        canceledAt == nil && revokedAt == nil && now < expiry
    }

    /// The highest period index whose start has passed as of `now`, or `nil` once
    /// the subscription has expired (`now >= expiry`) or the period is degenerate
    /// (`periodSeconds == 0`): no period is chargeable then.
    ///
    /// Period 0 covers `[billingAnchor, billingAnchor + periodSeconds)`; a `now`
    /// before the anchor still maps to period 0 (matching the reference SDK's
    /// `max(0, floor((now - anchor) / period))`).
    public func duePeriod(at now: UInt64) -> Int? {
        guard periodSeconds > 0, now < expiry else { return nil }
        guard now > billingAnchor else { return 0 }
        return Int((now - billingAnchor) / periodSeconds)
    }

    /// Whether a not-yet-charged period is due as of `now` (the subscription is
    /// active and ``duePeriod(at:)`` is past ``lastChargedPeriod``).
    public func hasChargeDue(at now: UInt64) -> Bool {
        guard isActive(at: now), let period = duePeriod(at: now) else { return false }
        return period > (lastChargedPeriod ?? -1)
    }
}

import Foundation
import MPPCore
import MPPEVM
import MPPTempo

/// Tempo glue from a verified subscription activation to a persisted
/// ``SubscriptionRecord``: builds the record the rail-agnostic ``SubscriptionEngine``
/// stores and renews. Keeps the engine free of Tempo specifics: it only ever sees a
/// ``SubscriptionRecord``.
public extension TempoSubscriptionVerifier.Verified {
    /// The persistable record for this verified activation.
    ///
    /// The economic terms (`amount`, `currency`, `recipient`, period, expiry), the
    /// `payer`, the bound `chainID`, and the signed key authorization all come from the
    /// verified credential. The caller supplies the application identity that is *not*
    /// in the credential:
    ///
    /// - Parameters:
    ///   - subscriptionID: the immutable id for this subscription.
    ///   - lookupKey: the customer/plan key the active subscription is found by; a new
    ///     subscription for the same key supersedes the old (see
    ///     ``SubscriptionEngine/activate(_:now:)``).
    ///   - billingAnchor: the whole-Unix-seconds instant period 0 begins (typically the
    ///     activation `now`).
    ///   - lastChargedPeriod: the highest period already charged. Defaults to `nil`
    ///     (nothing charged yet; the renewal engine charges period 0 onward). An
    ///     operator that settles period 0 at activation passes `0`.
    func subscriptionRecord(
        subscriptionID: String,
        lookupKey: String,
        billingAnchor: UInt64,
        lastChargedPeriod: Int? = nil
    ) -> SubscriptionRecord {
        SubscriptionRecord(
            subscriptionID: subscriptionID,
            lookupKey: lookupKey,
            keyAuthorization: serializedAuthorization,
            payer: payer,
            chainID: chainID,
            amount: request.amount,
            currency: request.currency,
            recipient: request.recipient,
            periodSeconds: request.periodSeconds,
            expiry: request.expirySeconds,
            billingAnchor: billingAnchor,
            externalId: request.externalId,
            lastChargedPeriod: lastChargedPeriod
        )
    }
}

public extension SubscriptionEngine {
    /// Persists a verified Tempo subscription as the active one for `lookupKey`,
    /// superseding any prior active subscription for that key, and returns the stored
    /// record. Convenience over
    /// ``subscriptionRecord(subscriptionID:lookupKey:billingAnchor:lastChargedPeriod:)``
    /// + ``activate(_:now:)``.
    ///
    /// - Parameters: see ``TempoSubscriptionVerifier/Verified/subscriptionRecord(subscriptionID:lookupKey:billingAnchor:lastChargedPeriod:)``;
    ///   `now` is the whole-Unix-seconds activation instant passed through to
    ///   ``activate(_:now:)`` (it cancels a superseded prior as of `now`).
    @discardableResult
    func activate(
        _ verified: TempoSubscriptionVerifier.Verified,
        subscriptionID: String,
        lookupKey: String,
        billingAnchor: UInt64,
        lastChargedPeriod: Int? = nil,
        now: UInt64
    ) async throws -> SubscriptionRecord {
        let record = verified.subscriptionRecord(
            subscriptionID: subscriptionID,
            lookupKey: lookupKey,
            billingAnchor: billingAnchor,
            lastChargedPeriod: lastChargedPeriod
        )
        try await activate(record, now: now)
        return record
    }
}

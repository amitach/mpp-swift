import Foundation

/// Makes the recurring charge for one billing period of a subscription.
///
/// This is the rail seam: ``SubscriptionEngine`` decides *when* a period is due and
/// claims it exactly once; the renewer performs the *actual* charge (for Tempo, a
/// `transferWithMemo` signed with the subscription's stored key authorization) and
/// returns a reference such as a transaction hash. `idempotencyReference` is stable
/// across retries of the same `(subscription, period)`, so a renewer that already
/// submitted that charge can return the existing reference instead of double-paying.
public protocol SubscriptionRenewer: Sendable {
    /// Charges `period` of `record`, returning a reference (a transaction hash).
    ///
    /// - Throws: to signal the charge did not happen; the engine releases its claim
    ///   so a later attempt can retry.
    func charge(
        _ record: SubscriptionRecord,
        period: Int,
        idempotencyReference: String
    ) async throws -> String
}

/// The result of attempting a renewal.
public enum RenewalOutcome: Sendable, Hashable {
    /// A period was charged: its index and the renewer's reference.
    case renewed(period: Int, reference: String)
    /// No not-yet-charged period is due as of `now` (the due period is already
    /// charged, or none has started).
    case upToDate
    /// Another renewer holds a fresh claim on the due period; this attempt did not
    /// charge.
    case inFlight
    /// The subscription is canceled, revoked, expired, or has been superseded by a
    /// newer subscription for its lookup key; it is not chargeable.
    case inactive
}

/// Drives subscription activation and renewal over a ``SubscriptionStore``.
///
/// Renewal is a two-phase atomic claim (the channel-store lesson: decide inside the
/// serialized update, so concurrent renewers cannot both charge a period):
/// 1. **Claim** - atomically stamp an ``SubscriptionRecord/InFlight`` for the due
///    period with a fresh ``attemptToken``, unless the period is already charged or a
///    non-stale claim is held.
/// 2. **Charge** - call the ``SubscriptionRenewer`` outside the lock with the stable
///    idempotency reference.
/// 3. **Commit** - atomically advance `lastChargedPeriod` and clear the claim, but
///    only if this attempt still owns it (a timed-out claim taken over by another
///    renewer must not be committed by the original).
///
/// Time is injected per call as whole Unix seconds (the `now:` parameter, like the
/// session method), and the ownership token via ``attemptToken`` (injectable for
/// deterministic tests); the engine reads no clock of its own.
public struct SubscriptionEngine: Sendable {
    private let store: any SubscriptionStore
    private let renewer: any SubscriptionRenewer
    private let renewalTimeout: UInt64
    private let attemptToken: @Sendable () -> String

    /// Creates the engine.
    ///
    /// - Parameters:
    ///   - store: the subscription persistence.
    ///   - renewer: the rail charge seam.
    ///   - renewalTimeout: seconds after which a stalled in-flight claim may be taken
    ///     over by another renewer (default 900, matching the reference SDK).
    ///   - attemptToken: a unique-per-call ownership token (default a fresh UUID).
    public init(
        store: any SubscriptionStore,
        renewer: any SubscriptionRenewer,
        renewalTimeout: UInt64 = 900,
        attemptToken: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.renewer = renewer
        self.renewalTimeout = renewalTimeout
        self.attemptToken = attemptToken
    }

    /// Stores `record` as the active subscription for its lookup key, superseding any
    /// prior active subscription for that key (the prior one is marked canceled as of
    /// `now`, so it stops renewing but is preserved for audit).
    public func activate(_ record: SubscriptionRecord, now: UInt64) async throws {
        if let priorID = await store.activeSubscription(forLookupKey: record.lookupKey),
           priorID != record.subscriptionID {
            try await store.update(priorID) { current in
                guard var prior = current, prior.canceledAt == nil, prior.revokedAt == nil else {
                    return current
                }
                prior.canceledAt = now
                return prior
            }
        }
        try await store.update(record.subscriptionID) { _ in record }
        await store.setActiveSubscription(record.subscriptionID, forLookupKey: record.lookupKey)
    }

    /// Marks the subscription canceled as of `now` (idempotent). Returns the updated
    /// record, or `nil` if unknown.
    @discardableResult
    public func cancel(subscriptionID: String, now: UInt64) async throws -> SubscriptionRecord? {
        try await store.update(subscriptionID) { current in
            guard var record = current, record.canceledAt == nil else { return current }
            record.canceledAt = now
            return record
        }
    }

    /// Marks the subscription revoked as of `now` (idempotent). Returns the updated
    /// record, or `nil` if unknown.
    @discardableResult
    public func revoke(subscriptionID: String, now: UInt64) async throws -> SubscriptionRecord? {
        try await store.update(subscriptionID) { current in
            guard var record = current, record.revokedAt == nil else { return current }
            record.revokedAt = now
            return record
        }
    }

    /// Charges the not-yet-charged period due as of `now`, if any, exactly once.
    ///
    /// - Throws: ``SubscriptionError/notFound`` if unknown, or rethrows the renewer's
    ///   error after releasing this attempt's claim.
    @discardableResult
    public func renew(subscriptionID: String, now: UInt64) async throws -> RenewalOutcome {
        guard let record = await store.record(subscriptionID) else {
            throw SubscriptionError.notFound
        }
        // Superseded subscriptions (no longer the active one for their lookup key)
        // must not bill, even if still otherwise active.
        let activeID = await store.activeSubscription(forLookupKey: record.lookupKey)
        guard activeID == nil || activeID == subscriptionID else { return .inactive }

        let token = attemptToken()
        let claimed = try await claim(subscriptionID, now: now, token: token)
        guard let claimed else { throw SubscriptionError.notFound }
        guard let flight = claimed.inFlight, flight.attempt == token else {
            return nonClaimOutcome(claimed, now: now)
        }

        let reference: String
        do {
            reference = try await renewer.charge(
                claimed, period: flight.period, idempotencyReference: flight.reference
            )
        } catch {
            await releaseClaim(subscriptionID, token: token)
            throw error
        }
        return try await commit(
            subscriptionID, period: flight.period, reference: reference, token: token
        )
    }

    // MARK: - Phases

    /// Phase 1: atomically stamp an in-flight claim for the due period, unless it is
    /// already charged or a non-stale claim is held. Returns the record after the
    /// attempt (its `inFlight` is this attempt's only if the claim was won).
    private func claim(
        _ subscriptionID: String, now: UInt64, token: String
    ) async throws -> SubscriptionRecord? {
        let timeout = renewalTimeout
        return try await store.update(subscriptionID) { current in
            guard var record = current else { throw SubscriptionError.notFound }
            guard record.isActive(at: now), let period = record.duePeriod(at: now),
                  period > (record.lastChargedPeriod ?? -1)
            else { return record }
            if let held = record.inFlight, now &- held.startedAt < timeout { return record }
            record.inFlight = SubscriptionRecord.InFlight(
                period: period,
                reference: "renewal:\(subscriptionID):\(period)",
                attempt: token,
                startedAt: now
            )
            return record
        }
    }

    /// Phase 3: advance `lastChargedPeriod` and clear the claim, but only if this
    /// attempt still owns it (a taken-over claim must not be committed here).
    private func commit(
        _ subscriptionID: String, period: Int, reference: String, token: String
    ) async throws -> RenewalOutcome {
        let committed = try await store.update(subscriptionID) { current in
            guard var record = current,
                  record.inFlight?.attempt == token, record.inFlight?.period == period
            else { return current }
            record.lastChargedPeriod = period
            record.lastReference = reference
            record.inFlight = nil
            return record
        }
        guard let committed, committed.lastChargedPeriod == period,
              committed.lastReference == reference
        else { return .inFlight }
        return .renewed(period: period, reference: reference)
    }

    /// Releases this attempt's claim (only if it still owns it) so a later renewal
    /// can retry after a failed charge.
    private func releaseClaim(_ subscriptionID: String, token: String) async {
        try? await store.update(subscriptionID) { current in
            guard var record = current, record.inFlight?.attempt == token else { return current }
            record.inFlight = nil
            return record
        }
    }

    /// Why a claim attempt did not win: inactive, already up to date, or a fresh
    /// claim held by another renewer.
    private func nonClaimOutcome(_ record: SubscriptionRecord, now: UInt64) -> RenewalOutcome {
        guard record.isActive(at: now) else { return .inactive }
        guard record.hasChargeDue(at: now) else { return .upToDate }
        return .inFlight
    }
}

/// A reason a subscription operation failed.
public enum SubscriptionError: Error, Sendable, Hashable {
    /// No subscription is recorded for the id.
    case notFound
}

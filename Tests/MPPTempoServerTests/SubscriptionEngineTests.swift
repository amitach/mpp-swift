import Foundation
import MPPCore
import MPPEVM
import MPPTempoServer
import Testing

@Suite("SubscriptionEngine")
struct SubscriptionEngineTests {
    private static let payerHex = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let currencyHex = "0x20c0000000000000000000000000000000000001"
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let anchor: UInt64 = 1000
    private static let period: UInt64 = 100
    private static let expiry: UInt64 = 1_000_000

    private func record(
        id: String = "sub-1",
        lookupKey: String = "cust-1:pro",
        externalId: String? = nil
    ) throws -> SubscriptionRecord {
        try SubscriptionRecord(
            subscriptionID: id,
            lookupKey: lookupKey,
            keyAuthorization: Data([0xAB, 0xCD]),
            payer: #require(EthereumAddress(hex: Self.payerHex)),
            chainID: 42431,
            amount: Amount("1000000"),
            currency: #require(EthereumAddress(hex: Self.currencyHex)),
            recipient: #require(EthereumAddress(hex: Self.recipientHex)),
            periodSeconds: Self.period,
            expiry: Self.expiry,
            billingAnchor: Self.anchor,
            externalId: externalId
        )
    }

    private func engine(
        store: any SubscriptionStore,
        renewer: any SubscriptionRenewer,
        renewalTimeout: UInt64 = 900,
        token: String? = nil
    ) -> SubscriptionEngine {
        if let token {
            return SubscriptionEngine(
                store: store, renewer: renewer, renewalTimeout: renewalTimeout,
                attemptToken: { token }
            )
        }
        return SubscriptionEngine(store: store, renewer: renewer, renewalTimeout: renewalTimeout)
    }

    // MARK: period math

    @Test("the due period is measured from the billing anchor and ends at expiry")
    func duePeriodMath() throws {
        let rec = try record()
        #expect(rec.duePeriod(at: Self.anchor - 50) == 0) // before the anchor is still period 0
        #expect(rec.duePeriod(at: Self.anchor) == 0)
        #expect(rec.duePeriod(at: Self.anchor + Self.period) == 1)
        #expect(rec.duePeriod(at: Self.anchor + Self.period * 3 + 5) == 3)
        #expect(rec.duePeriod(at: Self.expiry) == nil) // expired: no period chargeable
        #expect(rec.hasChargeDue(at: Self.anchor + 50)) // period 0 not yet charged
    }

    // MARK: activation + supersession

    @Test("activate stores the record and points its lookup key at it")
    func activateStores() async throws {
        let store = InMemorySubscriptionStore()
        let engine = engine(store: store, renewer: StubRenewer())
        try await engine.activate(record(), now: Self.anchor)
        #expect(await store.record("sub-1")?.subscriptionID == "sub-1")
        #expect(await store.activeSubscription(forLookupKey: "cust-1:pro") == "sub-1")
    }

    @Test("a new subscription for the same lookup key supersedes and cancels the old")
    func supersede() async throws {
        let store = InMemorySubscriptionStore()
        let engine = engine(store: store, renewer: StubRenewer())
        try await engine.activate(record(id: "old"), now: Self.anchor)
        try await engine.activate(record(id: "new"), now: Self.anchor + 10)
        #expect(await store.activeSubscription(forLookupKey: "cust-1:pro") == "new")
        #expect(await store.record("old")?.canceledAt == Self.anchor + 10)
        #expect(await store.record("new")?.canceledAt == nil)
    }

    // MARK: renew outcomes

    @Test("a due period is charged once with the stable idempotency reference")
    func renewsDuePeriod() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer(reference: "0xtx")
        let engine = engine(store: store, renewer: renewer)
        try await engine.activate(record(), now: Self.anchor)

        let outcome = try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 50)
        #expect(outcome == .renewed(period: 0, reference: "0xtx"))
        let calls = await renewer.calls
        #expect(calls.count == 1)
        #expect(calls.first?.period == 0)
        #expect(calls.first?.reference == "renewal:sub-1:0")
        #expect(await store.record("sub-1")?.lastChargedPeriod == 0)
        #expect(await store.record("sub-1")?.inFlight == nil)
    }

    @Test("an already-charged period is up to date and does not charge again")
    func upToDateWhenCharged() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer()
        let engine = engine(store: store, renewer: renewer)
        try await engine.activate(record(), now: Self.anchor)
        _ = try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 50)

        // Same period, second renew: nothing new is due.
        let outcome = try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 60)
        #expect(outcome == .upToDate)
        #expect(await renewer.calls.count == 1)
    }

    @Test("a canceled, revoked, or expired subscription is inactive")
    func inactiveStates() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer()
        let engine = engine(store: store, renewer: renewer)
        try await engine.activate(record(), now: Self.anchor)

        try await engine.cancel(subscriptionID: "sub-1", now: Self.anchor + 10)
        #expect(try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 50) == .inactive)

        try await engine.activate(record(id: "rev", lookupKey: "k2"), now: Self.anchor)
        try await engine.revoke(subscriptionID: "rev", now: Self.anchor + 10)
        #expect(try await engine.renew(subscriptionID: "rev", now: Self.anchor + 50) == .inactive)

        try await engine.activate(record(id: "exp", lookupKey: "k3"), now: Self.anchor)
        #expect(try await engine.renew(subscriptionID: "exp", now: Self.expiry + 1) == .inactive)
        #expect(await renewer.calls.isEmpty)
    }

    @Test("a superseded subscription does not bill")
    func supersededDoesNotBill() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer()
        let engine = engine(store: store, renewer: renewer)
        try await engine.activate(record(id: "old"), now: Self.anchor)
        try await engine.activate(record(id: "new"), now: Self.anchor + 10)
        // The old record is canceled by supersession and no longer the active pointer.
        #expect(try await engine.renew(subscriptionID: "old", now: Self.anchor + 50) == .inactive)
        #expect(await renewer.calls.isEmpty)
    }

    @Test("renew throws notFound for an unknown subscription")
    func renewNotFound() async throws {
        let engine = engine(store: InMemorySubscriptionStore(), renewer: StubRenewer())
        await #expect(throws: SubscriptionError.notFound) {
            _ = try await engine.renew(subscriptionID: "ghost", now: Self.anchor)
        }
    }

    // MARK: claim safety

    @Test("a failed charge releases the claim so a later renew retries")
    func failedChargeReleasesClaim() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer(reference: "0xtx", failFirst: 1)
        let engine = engine(store: store, renewer: renewer)
        try await engine.activate(record(), now: Self.anchor)

        await #expect(throws: StubRenewer.Boom.self) {
            _ = try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 50)
        }
        // The claim was released, so a retry proceeds and succeeds.
        #expect(await store.record("sub-1")?.inFlight == nil)
        let outcome = try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 60)
        #expect(outcome == .renewed(period: 0, reference: "0xtx"))
        #expect(await renewer.calls.count == 2)
    }

    @Test("a stale in-flight claim is taken over and charged")
    func staleClaimTakenOver() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer(reference: "0xtx")
        let engine = engine(store: store, renewer: renewer, renewalTimeout: 30)
        var rec = try record()
        // A claim stamped long ago by a renewer that never committed.
        rec.inFlight = .init(
            period: 0, reference: "renewal:sub-1:0", attempt: "dead", startedAt: Self.anchor
        )
        let seeded = rec
        try await store.update("sub-1") { _ in seeded }
        await store.setActiveSubscription("sub-1", forLookupKey: "cust-1:pro")

        // Still in period 0, but elapsed since the claim (50s) exceeds the 30s
        // timeout, so the stale claim is taken over and period 0 is charged.
        let outcome = try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 50)
        #expect(outcome == .renewed(period: 0, reference: "0xtx"))
        #expect(await renewer.calls.count == 1)
    }

    @Test("a fresh in-flight claim held by another renewer blocks this one")
    func freshClaimBlocks() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer()
        let engine = engine(store: store, renewer: renewer, renewalTimeout: 900)
        var rec = try record()
        rec.inFlight = .init(
            period: 0, reference: "renewal:sub-1:0", attempt: "other", startedAt: Self.anchor + 40
        )
        let seeded = rec
        try await store.update("sub-1") { _ in seeded }
        await store.setActiveSubscription("sub-1", forLookupKey: "cust-1:pro")

        let outcome = try await engine.renew(subscriptionID: "sub-1", now: Self.anchor + 50)
        #expect(outcome == .inFlight)
        #expect(await renewer.calls.isEmpty)
    }

    @Test("concurrent renewals charge a period exactly once")
    func concurrentRenewChargesOnce() async throws {
        let store = InMemorySubscriptionStore()
        let renewer = StubRenewer(reference: "0xtx")
        let engine = engine(store: store, renewer: renewer)
        try await engine.activate(record(), now: Self.anchor)

        let outcomes = try await withThrowingTaskGroup(of: RenewalOutcome.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { try await engine.renew(
                    subscriptionID: "sub-1",
                    now: Self.anchor + 50
                ) }
            }
            var collected: [RenewalOutcome] = []
            for try await outcome in group {
                collected.append(outcome)
            }
            return collected
        }
        let renewed = outcomes
            .filter { if case .renewed = $0 { return true } else { return false } }
        #expect(renewed.count == 1)
        #expect(await renewer.calls.count == 1)
        #expect(await store.record("sub-1")?.lastChargedPeriod == 0)
    }
}

// MARK: test support

/// Records the charges asked of it; optionally fails the first `failFirst` calls.
private actor StubRenewer: SubscriptionRenewer {
    struct Boom: Error {}

    private(set) var calls: [(period: Int, reference: String)] = []
    private let reference: String
    private var remainingFailures: Int

    init(reference: String = "0xref", failFirst: Int = 0) {
        self.reference = reference
        remainingFailures = failFirst
    }

    func charge(
        _: SubscriptionRecord,
        period: Int,
        idempotencyReference: String
    ) async throws -> String {
        calls.append((period, idempotencyReference))
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw Boom()
        }
        return reference
    }
}

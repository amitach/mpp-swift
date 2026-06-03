import Foundation
import HTTPTypes
import MPPCore
import MPPEVM
import MPPServer
import Testing
@testable import MPPTempoServer

// The Tempo returning-subscriber authorizer: resolve identity -> active subscription ->
// engine.renew,
// mapping renewed/upToDate -> authorized(receipt), inFlight -> 409, charge-throw -> 503,
// inactive/unresolved/no-active -> nil (fall through to the 402 activation path). Drives real
// engine
// outcomes via a controllable renewer; the on-chain charge is the renewer seam (stubbed here).
@Suite("SubscriptionAuthorizer")
struct SubscriptionAuthorizerTests {
    static let payerHex = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    static let currencyHex = "0x20c0000000000000000000000000000000000001"
    static let recipientHex = "0x1111111111111111111111111111111111111111"
    static let anchor: UInt64 = 1000
    static let period: UInt64 = 100
    static let lookupKey = "cust-1:pro"
    static let subID = "sub-1"

    private func record() throws -> SubscriptionRecord {
        try SubscriptionRecord(
            subscriptionID: Self.subID,
            lookupKey: Self.lookupKey,
            keyAuthorization: Data([0xAB, 0xCD]),
            payer: #require(EthereumAddress(hex: Self.payerHex)),
            chainID: 42431,
            amount: Amount("1000000"),
            currency: #require(EthereumAddress(hex: Self.currencyHex)),
            recipient: #require(EthereumAddress(hex: Self.recipientHex)),
            periodSeconds: Self.period,
            expiry: 1_000_000,
            billingAnchor: Self.anchor
        )
    }

    private func request() -> HTTPRequest {
        HTTPRequest(method: .get, scheme: "https", authority: "api.example.com", path: "/r")
    }

    private func date(_ seconds: UInt64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func authorizer(
        engine: SubscriptionEngine, resolvesTo key: String?
    ) throws -> SubscriptionAuthorizer {
        try SubscriptionAuthorizer(
            engine: engine, routeMethod: MethodName("tempo"), resolveLookupKey: { _ in key }
        )
    }

    /// An engine with one active subscription, plus an authorizer resolving to its lookup key.
    private func active(
        renewer: any SubscriptionRenewer
    ) async throws -> (SubscriptionAuthorizer, SubscriptionEngine) {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: renewer)
        try await engine.activate(record(), now: Self.anchor)
        return try (authorizer(engine: engine, resolvesTo: Self.lookupKey), engine)
    }

    @Test("a due period is renewed inline and authorized with the new receipt")
    func renewsWhenDue() async throws {
        let renewer = StubAuthRenewer(reference: "0xtx1")
        let (authorizer, _) = try await active(renewer: renewer)
        let outcome = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor))
        guard case let .authorized(receipt) = outcome else {
            Issue.record("expected .authorized, got \(String(describing: outcome))"); return
        }
        #expect(receipt?.reference == "0xtx1")
        #expect(receipt?.method.rawValue == "tempo")
        #expect(await renewer.chargeCount == 1)
    }

    @Test("an already-charged period authorizes without re-charging (up to date)")
    func upToDateDoesNotRecharge() async throws {
        let renewer = StubAuthRenewer(reference: "0xtx1")
        let (authorizer, _) = try await active(renewer: renewer)
        _ = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor)) // charges 0
        let outcome = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor))
        guard case let .authorized(receipt) = outcome else {
            Issue.record("expected .authorized, got \(String(describing: outcome))"); return
        }
        #expect(receipt?.reference == "0xtx1") // the last settlement reference, not a new charge
        #expect(await renewer.chargeCount == 1)
    }

    @Test("a fresh in-flight claim maps to 409 Retry-After (no-store)")
    func inFlightMaps409() async throws {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: StubAuthRenewer())
        var rec = try record()
        rec.inFlight = .init(
            period: 0, reference: "renewal:sub-1:0", attempt: "other", startedAt: Self.anchor
        )
        let seeded = rec
        try await store.update(Self.subID) { _ in seeded }
        await store.setActiveSubscription(Self.subID, forLookupKey: Self.lookupKey)
        let authorizer = try authorizer(engine: engine, resolvesTo: Self.lookupKey)
        let outcome = await authorizer.authorize(
            request(),
            body: Data(),
            now: date(Self.anchor + 10)
        )
        guard case let .respond(response, _) = outcome else {
            Issue.record("expected .respond, got \(String(describing: outcome))"); return
        }
        #expect(response.status.code == 409)
        #expect(response.headerFields[.retryAfter] == "1")
        #expect(response.headerFields[.cacheControl] == "no-store")
    }

    @Test("a transient charge failure maps to 503 Retry-After")
    func chargeFailureMaps503() async throws {
        let (authorizer, _) = try await active(renewer: AlwaysThrowingRenewer())
        let outcome = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor))
        guard case let .respond(response, _) = outcome else {
            Issue.record("expected .respond, got \(String(describing: outcome))"); return
        }
        #expect(response.status.code == 503)
        #expect(response.headerFields[.retryAfter] == "1")
    }

    @Test("an unresolvable identity falls through to the 402 path (nil)")
    func unresolvedFallsThrough() async throws {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: StubAuthRenewer())
        try await engine.activate(record(), now: Self.anchor)
        let authorizer = try authorizer(engine: engine, resolvesTo: nil)
        let outcome = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor))
        #expect(outcome == nil)
    }

    @Test("no active subscription for the resolved key falls through (nil)")
    func noActiveFallsThrough() async throws {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: StubAuthRenewer())
        let authorizer = try authorizer(engine: engine, resolvesTo: "nobody")
        let outcome = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor))
        #expect(outcome == nil)
    }

    @Test("a canceled subscription falls through to the 402 path (nil)")
    func canceledFallsThrough() async throws {
        let (authorizer, engine) = try await active(renewer: StubAuthRenewer())
        try await engine.cancel(subscriptionID: Self.subID, now: Self.anchor)
        let outcome = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor))
        #expect(outcome == nil)
    }

    @Test("a vanished record (SubscriptionError.notFound) falls through, not a 503 retry loop")
    func vanishedRecordFallsThrough() async throws {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: StubAuthRenewer())
        // An active pointer to a subscription whose record does not exist: a TOCTOU removal between
        // the active-subscription read and renew. engine.renew throws SubscriptionError.notFound,
        // which is permanent, so the authorizer falls through (nil), not a retryable 503.
        await store.setActiveSubscription("ghost", forLookupKey: Self.lookupKey)
        let authorizer = try authorizer(engine: engine, resolvesTo: Self.lookupKey)
        let outcome = await authorizer.authorize(request(), body: Data(), now: date(Self.anchor))
        #expect(outcome == nil)
    }
}

/// A renewer that succeeds with a fixed reference and counts charges.
private actor StubAuthRenewer: SubscriptionRenewer {
    private(set) var chargeCount = 0
    private let reference: String

    init(reference: String = "0xref") {
        self.reference = reference
    }

    func charge(
        _: SubscriptionRecord,
        period _: Int,
        idempotencyReference _: String
    ) async -> String {
        chargeCount += 1
        return reference
    }
}

/// A renewer whose charge always fails, to drive the transient-failure (503) path.
private struct AlwaysThrowingRenewer: SubscriptionRenewer {
    struct Boom: Error {}
    func charge(
        _: SubscriptionRecord, period _: Int, idempotencyReference _: String
    ) async throws -> String {
        throw Boom()
    }
}

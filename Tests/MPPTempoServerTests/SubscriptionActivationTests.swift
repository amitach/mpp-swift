import Foundation
import MPPCore
import MPPEVM
import MPPTempo
import MPPTempoServer
import Testing

// Activation wiring: a credential the client mints verifies, and the verified
// activation persists into a SubscriptionStore as a renewable SubscriptionRecord.
// Reuses the module-global `signer(byte:)`/`now`/`realm` (see TempoProofVerifierTests).
@Suite("Subscription activation")
struct SubscriptionActivationTests {
    private static let currencyHex = "0x20c0000000000000000000000000000000000001"
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let requestKeyHex = "0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c"
    private static let chainID: UInt64 = 42431
    // The subscription expires in 2030; the global `now` (2026) sits before it.
    private static let expiryEpoch: TimeInterval = 1_893_456_000
    // The activation instant (period 0 begins here); before expiry.
    private static let anchor: UInt64 = 1_767_312_000

    private struct NoopRenewer: SubscriptionRenewer {
        func charge(_: SubscriptionRecord, period _: Int, idempotencyReference: String) -> String {
            idempotencyReference
        }
    }

    private func challenge() throws -> Challenge {
        let expiryISO = ISO8601DateFormatter()
            .string(from: Date(timeIntervalSince1970: Self.expiryEpoch))
        let object: [String: JSONValue] = [
            "amount": .string("1000000"),
            "currency": .string(Self.currencyHex),
            "recipient": .string(Self.recipientHex),
            "periodCount": .string("1"),
            "periodUnit": .string("week"),
            "subscriptionExpires": .string(expiryISO),
            "externalId": .string("ext-42"),
            "methodDetails": .object([
                "accessKey": .object([
                    "accessKeyAddress": .string(Self.requestKeyHex),
                    "keyType": .string("secp256k1"),
                ]),
                "chainId": .integer(Int64(Self.chainID)),
            ]),
        ]
        return try Challenge(
            id: "sub-1", realm: realm, method: MethodName("tempo"),
            intent: .subscription, request: EncodedJSON(json: .object(object))
        )
    }

    /// The verified activation a client credential produces against the verifier.
    private func verified() async throws -> TempoSubscriptionVerifier.Verified {
        let credential = try await #require(TempoSubscriptionMethod(signer: signer(byte: 1)))
            .buildCredential(for: challenge())
        return try TempoSubscriptionVerifier(defaultChainID: Self.chainID).verified(
            credential,
            now: now
        )
    }

    @Test("activating a verified subscription persists it and points the lookup key at it")
    func activatePersists() async throws {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: NoopRenewer())
        let verified = try await verified()

        let record = try await engine.activate(
            verified, subscriptionID: "sub-1", lookupKey: "cust-1",
            billingAnchor: Self.anchor, now: Self.anchor
        )

        #expect(await store.activeSubscription(forLookupKey: "cust-1") == "sub-1")
        let stored = try #require(await store.record("sub-1"))
        #expect(stored == record)
        #expect(stored.amount.rawValue == "1000000")
        #expect(stored.currency == EthereumAddress(hex: Self.currencyHex))
        #expect(stored.recipient == EthereumAddress(hex: Self.recipientHex))
        #expect(stored.periodSeconds == 604_800) // 1 week
        #expect(stored.expiry == UInt64(Self.expiryEpoch))
        #expect(stored.chainID == Self.chainID)
        #expect(stored.billingAnchor == Self.anchor)
        #expect(stored.externalId == "ext-42")
        // Default: nothing charged yet, so period 0 is due as of the anchor.
        #expect(stored.lastChargedPeriod == nil)
        #expect(stored.hasChargeDue(at: Self.anchor))
        // The stored authorization is byte-real: it recovers to the recorded payer.
        #expect(try TempoKeyAuthorization.recover(serialized: stored.keyAuthorization) == stored
            .payer)
        #expect(stored.payer == verified.payer)
    }

    @Test("lastChargedPeriod can be set to 0 for activation-time settlement")
    func activationSettlesPeriodZero() async throws {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: NoopRenewer())
        let verified = try await verified()

        let record = try await engine.activate(
            verified, subscriptionID: "s", lookupKey: "k",
            billingAnchor: Self.anchor, lastChargedPeriod: 0, now: Self.anchor
        )

        #expect(record.lastChargedPeriod == 0)
        // Period 0 already charged, so nothing is due at the anchor.
        #expect(record.hasChargeDue(at: Self.anchor) == false)
        #expect(await store.record("s")?.lastChargedPeriod == 0)
    }

    @Test("re-activating for the same lookup key supersedes and cancels the prior subscription")
    func supersedes() async throws {
        let store = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(store: store, renewer: NoopRenewer())
        let verified = try await verified()

        _ = try await engine.activate(
            verified, subscriptionID: "old", lookupKey: "k",
            billingAnchor: Self.anchor, now: Self.anchor
        )
        _ = try await engine.activate(
            verified, subscriptionID: "new", lookupKey: "k",
            billingAnchor: Self.anchor + 10, now: Self.anchor + 10
        )

        #expect(await store.activeSubscription(forLookupKey: "k") == "new")
        #expect(await store.record("old")?.canceledAt == Self.anchor + 10)
        #expect(await store.record("new")?.canceledAt == nil)
    }

    @Test("the record builder maps the verified terms, payer, and authorization bytes")
    func builderMaps() async throws {
        let verified = try await verified()
        let record = verified.subscriptionRecord(
            subscriptionID: "s", lookupKey: "k", billingAnchor: Self.anchor
        )

        #expect(record.keyAuthorization == verified.serializedAuthorization)
        #expect(record.payer == verified.payer)
        #expect(record.chainID == Self.chainID)
        #expect(record.amount == verified.request.amount)
        #expect(record.recipient == verified.request.recipient)
        #expect(record.inFlight == nil)
        #expect(record.lastReference == nil)
        #expect(record.canceledAt == nil)
    }
}

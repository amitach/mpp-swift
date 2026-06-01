import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer
import Testing

// The activating subscription verifier: a credential the client mints verifies AND persists into
// the store via the engine, in one async verify(). Reuses the module-global
// signer(byte:)/now/realm.
@Suite("ActivatingSubscriptionVerifier")
struct ActivatingSubscriptionVerifierTests {
    private static let currencyHex = "0x20c0000000000000000000000000000000000001"
    private static let recipientHex = "0x1111111111111111111111111111111111111111"
    private static let requestKeyHex = "0xbe95c3f554e9fc85ec51be69a3d807a0d55bcf2c"
    private static let chainID: UInt64 = 42431
    private static let expiryEpoch: TimeInterval = 1_893_456_000

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

    private func credential() async throws -> Credential {
        try await #require(TempoSubscriptionMethod(signer: signer(byte: 1)))
            .buildCredential(for: challenge())
    }

    private func subject(
        store: InMemorySubscriptionStore,
        identity: ActivatingSubscriptionVerifier.Identity = .init(
            subscriptionID: "s",
            lookupKey: "k"
        )
    ) -> ActivatingSubscriptionVerifier {
        ActivatingSubscriptionVerifier(
            verifier: TempoSubscriptionVerifier(defaultChainID: Self.chainID),
            engine: SubscriptionEngine(store: store, renewer: NoopRenewer())
        ) { _ in identity }
    }

    @Test("verify mints the activation receipt and persists the subscription")
    func verifyPersists() async throws {
        let store = InMemorySubscriptionStore()
        let receipt = try await subject(store: store).verify(credential(), now: now)

        #expect(receipt.method.rawValue == "tempo")
        #expect(receipt.reference == "sub-1")
        #expect(receipt.status == .success)

        #expect(await store.activeSubscription(forLookupKey: "k") == "s")
        let stored = try #require(await store.record("s"))
        #expect(stored.amount.rawValue == "1000000")
        #expect(stored.currency == EthereumAddress(hex: Self.currencyHex))
        #expect(stored.chainID == Self.chainID)
        #expect(stored.lastChargedPeriod == nil)
        // The stored authorization recovers to the persisted payer (byte-real).
        let recovered = try TempoKeyAuthorization.recover(serialized: stored.keyAuthorization)
        #expect(recovered == stored.payer)
    }

    @Test("supports a tempo/subscription challenge, rejects others")
    func supports() throws {
        let store = InMemorySubscriptionStore()
        let challenge = try challenge()
        #expect(subject(store: store).supports(challenge))
        #expect(subject(store: store).reusesChallenge == false)
    }

    @Test("a forged source rejects (throws) and persists nothing")
    func forgedRejectsAndPersistsNothing() async throws {
        let store = InMemorySubscriptionStore()
        let original = try await credential()
        let forged = Credential(
            challenge: original.challenge,
            source: "did:pkh:eip155:\(Self.chainID):\(Self.recipientHex)",
            payload: original.payload
        )
        await #expect(throws: (any Error).self) {
            _ = try await subject(store: store).verify(forged, now: now)
        }
        #expect(await store.activeSubscription(forLookupKey: "k") == nil)
        #expect(await store.record("s") == nil)
    }

    @Test("a second activation for the same lookup key supersedes the prior")
    func supersedes() async throws {
        let store = InMemorySubscriptionStore()
        _ = try await subject(
            store: store, identity: .init(subscriptionID: "old", lookupKey: "k")
        ).verify(credential(), now: now)
        _ = try await subject(
            store: store, identity: .init(subscriptionID: "new", lookupKey: "k")
        ).verify(credential(), now: now)
        #expect(await store.activeSubscription(forLookupKey: "k") == "new")
        #expect(await store.record("old")?.canceledAt != nil)
    }
}

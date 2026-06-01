import Foundation
import MPPCore
import MPPEVM
import MPPTempo
import MPPTempoServer
import Testing

// The concrete on-chain renewer, hermetic: a stub charge builder records the parameters it is
// handed and returns canned tx bytes; a stub `submit` returns a canned receipt. Covers the
// provisioning rule (first charge attaches the authorization, later charges omit it), the revert
// and missing-key failures, and one end-to-end pass through SubscriptionEngine.
@Suite("TempoSubscriptionRenewer")
struct TempoSubscriptionRenewerTests {
    private let lookupKey = "cust-1"
    private let serverId = "api.example.com"
    private let keyAuthorization = Data([0xDE, 0xAD, 0xBE, 0xEF])

    /// Records the parameters/chain it was asked to build, returns canned `0x76` bytes.
    private final class RecordingChargeBuilder: TempoSubscriptionChargeTxBuilder,
        @unchecked Sendable {
        private let lock = NSLock()
        private var parameters: TempoSubscriptionChargeParameters?
        private var chainID: UInt64?
        var capturedParameters: TempoSubscriptionChargeParameters? {
            lock.withLock { parameters }
        }

        var capturedChainID: UInt64? {
            lock.withLock { chainID }
        }

        func buildSubscriptionChargeTransaction(
            _ parameters: TempoSubscriptionChargeParameters, chainID: UInt64
        ) async throws -> Data {
            lock.withLock {
                self.parameters = parameters
                self.chainID = chainID
            }
            return Data([0x76, 0x01])
        }
    }

    private func record(lastChargedPeriod: Int? = nil) throws -> SubscriptionRecord {
        try SubscriptionRecord(
            subscriptionID: "sub-1",
            lookupKey: lookupKey,
            keyAuthorization: keyAuthorization,
            payer: #require(EthereumAddress(hex: "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf")),
            chainID: 42431,
            amount: Amount("1000000"),
            currency: #require(EthereumAddress(hex: "0x20c0000000000000000000000000000000000001")),
            recipient: #require(EthereumAddress(hex: "0x1111111111111111111111111111111111111111")),
            periodSeconds: 604_800,
            expiry: 1_893_456_000,
            billingAnchor: 1_700_000_000,
            lastChargedPeriod: lastChargedPeriod
        )
    }

    private func provisionedStore() async throws -> InMemoryAccessKeyStore {
        let store = InMemoryAccessKeyStore()
        _ = try await store.provision(forLookupKey: lookupKey)
        return store
    }

    private func renewer(
        builder: any TempoSubscriptionChargeTxBuilder,
        accessKeys: any AccessKeyStore,
        succeeded: Bool = true,
        hash: String = "0xfeed"
    ) -> TempoSubscriptionRenewer {
        TempoSubscriptionRenewer(
            builder: builder,
            accessKeys: accessKeys,
            serverId: serverId
        ) { _ in
            TransactionReceipt(transactionHash: hash, succeeded: succeeded, blockNumber: 1)
        }
    }

    @Test("the first charge attaches the key authorization and returns the settled hash")
    func firstChargeProvisions() async throws {
        let store = try await provisionedStore()
        let builder = RecordingChargeBuilder()
        let reference = try await renewer(builder: builder, accessKeys: store).charge(
            record(lastChargedPeriod: nil), period: 0, idempotencyReference: "renewal:sub-1:0"
        )
        #expect(reference == "0xfeed")
        let params = try #require(builder.capturedParameters)
        #expect(params.keyAuthorization == keyAuthorization)
        #expect(params
            .currency == EthereumAddress(hex: "0x20c0000000000000000000000000000000000001"))
        #expect(params
            .recipient == EthereumAddress(hex: "0x1111111111111111111111111111111111111111"))
        #expect(params.amount == "1000000")
        #expect(params.memo == Attribution.encode(
            serverId: serverId,
            challengeId: "renewal:sub-1:0"
        ))
        #expect(await params.accessKeyPrivateKey == (store.privateKey(forLookupKey: lookupKey)))
        #expect(builder.capturedChainID == 42431)
    }

    @Test("a later charge omits the key authorization (already provisioned)")
    func laterChargeOmitsAuthorization() async throws {
        let store = try await provisionedStore()
        let builder = RecordingChargeBuilder()
        _ = try await renewer(builder: builder, accessKeys: store).charge(
            record(lastChargedPeriod: 0), period: 1, idempotencyReference: "renewal:sub-1:1"
        )
        #expect(builder.capturedParameters?.keyAuthorization == nil)
    }

    @Test("a reverted transaction throws chargeReverted with the hash")
    func revertThrows() async throws {
        let store = try await provisionedStore()
        let subject = renewer(
            builder: RecordingChargeBuilder(), accessKeys: store, succeeded: false, hash: "0xbad"
        )
        await #expect(throws: TempoSubscriptionRenewer.Error.chargeReverted("0xbad")) {
            _ = try await subject.charge(record(), period: 0, idempotencyReference: "r")
        }
    }

    @Test("a missing access key throws accessKeyMissing")
    func missingAccessKeyThrows() async throws {
        let subject = renewer(
            builder: RecordingChargeBuilder(),
            accessKeys: InMemoryAccessKeyStore()
        )
        await #expect(throws: TempoSubscriptionRenewer.Error.accessKeyMissing) {
            _ = try await subject.charge(record(), period: 0, idempotencyReference: "r")
        }
    }

    @Test("end-to-end through SubscriptionEngine: a due period charges and the record advances")
    func endToEndThroughEngine() async throws {
        let store = try await provisionedStore()
        let builder = RecordingChargeBuilder()
        let subStore = InMemorySubscriptionStore()
        let engine = SubscriptionEngine(
            store: subStore, renewer: renewer(builder: builder, accessKeys: store)
        )
        try await engine.activate(record(lastChargedPeriod: nil), now: 1_700_000_000)

        let outcome = try await engine.renew(subscriptionID: "sub-1", now: 1_700_000_001)

        #expect(outcome == .renewed(period: 0, reference: "0xfeed"))
        #expect(await subStore.record("sub-1")?.lastChargedPeriod == 0)
        #expect(await subStore.record("sub-1")?.lastReference == "0xfeed")
        // The engine's first charge is the provisioning one (authorization attached).
        #expect(builder.capturedParameters?.keyAuthorization == keyAuthorization)
    }
}

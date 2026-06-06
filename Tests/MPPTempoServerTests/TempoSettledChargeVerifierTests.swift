import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import MPPTempoServer
import Testing

// Server-side settled-charge verification, the counterpart to TempoSettledChargeMethodTests. A stub
// TempoChargeSettlement returns crafted receipts (with TransferWithMemo logs), so the matching,
// memo, revert, single-use, and mode (hash/transaction) logic is proven without a chain. The live
// Moderato e2e is the authoritative on-chain check. (`chainId`/`realm`/`now` are the module-shared
// fixtures from TempoProofVerifierTests.)
@Suite("TempoSettledChargeVerifier")
struct TempoSettledChargeVerifierTests {
    private static let payer = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf" // key 0x..01
    private static let currency = "0x20C0000000000000000000000000000000000001"
    private static let recipient = "0x1111111111111111111111111111111111111111"
    private static let challengeId = "settled-charge-1"
    private static let txHash = "0xfeedface"

    private func memo() -> Data {
        Attribution.encode(serverId: realm, challengeId: Self.challengeId)
    }

    private func verifier(
        settlement: any TempoChargeSettlement,
        replayStore: any ReplayStore = InMemoryReplayStore()
    ) -> TempoSettledChargeVerifier {
        TempoSettledChargeVerifier(
            settlement: settlement, replayStore: replayStore, defaultChainId: TempoChain.mainnet
        )
    }

    /// A non-zero `tempo`/`charge` challenge with recipient + currency (+ optional pinned memo).
    private func chargeChallenge(
        amount: String = "1000000",
        pinnedMemo: String? = nil
    ) throws -> Challenge {
        var details: [String: JSONValue] = ["chainId": .integer(Int64(chainId))]
        if let pinnedMemo { details["memo"] = .string(pinnedMemo) }
        let request = EncodedJSON(json: .object([
            "amount": .string(amount),
            "recipient": .string(Self.recipient),
            "currency": .string(Self.currency),
            "methodDetails": .object(details),
        ]))
        return try Challenge(
            id: Self.challengeId, realm: realm,
            method: MethodName("tempo"), intent: IntentName("charge"), request: request
        )
    }

    private func credential(
        _ challenge: Challenge,
        type: String,
        field: (String, String)
    ) throws -> Credential {
        try Credential(
            challenge: challenge,
            source: ProofSource.did(
                address: #require(EthereumAddress(hex: Self.payer)),
                chainId: chainId
            ),
            payload: ["type": .string(type), field.0: .string(field.1)]
        )
    }

    // A 32-byte indexed topic word for an address (12 zero bytes + the 20 address bytes).
    private func addressTopic(_ hex: String) throws -> String {
        try (Data(repeating: 0, count: 12) + #require(EthereumAddress(hex: hex)).bytes).hexPrefixed
    }

    /// A receipt whose log set contains a `TransferWithMemo` for the given fields.
    private func receipt(
        succeeded: Bool = true,
        currency: String? = currency,
        from: String? = payer,
        recipient: String? = recipient,
        amount: String = "1000000",
        memo: Data? = nil,
        hash: String = txHash
    ) throws -> TransactionReceipt {
        let log = try EVMLog(
            address: currency ?? Self.currency,
            topics: [
                TIP20TransferEvent.transferWithMemoTopic.hexPrefixed,
                addressTopic(from ?? Self.payer),
                addressTopic(recipient ?? Self.recipient),
                (memo ?? self.memo()).hexPrefixed,
            ],
            data: #require(EIP712.uint256(decimal: amount)).hexPrefixed
        )
        return TransactionReceipt(
            transactionHash: hash, succeeded: succeeded, blockNumber: 1, logs: [log]
        )
    }

    /// A receipt carrying several `TransferWithMemo` logs with identical financials but the given
    /// memos, in order (a batched / multi-call transaction).
    private func receipt(memos: [Data], amount: String = "1000000") throws -> TransactionReceipt {
        let logs = try memos.map { memo in
            try EVMLog(
                address: Self.currency,
                topics: [
                    TIP20TransferEvent.transferWithMemoTopic.hexPrefixed,
                    addressTopic(Self.payer),
                    addressTopic(Self.recipient),
                    memo.hexPrefixed,
                ],
                data: #require(EIP712.uint256(decimal: amount)).hexPrefixed
            )
        }
        return TransactionReceipt(
            transactionHash: Self.txHash, succeeded: true, blockNumber: 1, logs: logs
        )
    }

    // MARK: supports

    @Test("supports a non-zero tempo/charge; not a zero-amount one")
    func supports() throws {
        let subject = try verifier(settlement: StubSettlement(receipt: receipt()))
        #expect(try subject.supports(chargeChallenge()))
        #expect(try subject.supports(chargeChallenge(amount: "0")) == false)
    }

    // MARK: hash mode

    @Test("a hash credential with a matching transfer settles, referencing the tx hash")
    func hashCredentialSettles() async throws {
        let subject = try verifier(settlement: StubSettlement(receipt: receipt()))
        let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
        let receipt = try await subject.verify(cred, now: now)
        #expect(receipt.reference == Self.txHash)
        #expect(try receipt.method == MethodName("tempo"))
    }

    @Test("a reverted transaction is not a payment")
    func revertedRejected() async throws {
        let subject = try verifier(settlement: StubSettlement(receipt: receipt(succeeded: false)))
        let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
            _ = try await subject.verify(cred, now: now)
        }
    }

    @Test("a transfer to the wrong recipient or amount does not match")
    func mismatchedTransferRejected() async throws {
        let wrongRecipient = try receipt(recipient: "0x2222222222222222222222222222222222222222")
        let wrongAmount = try receipt(amount: "999")
        for bad in [wrongRecipient, wrongAmount] {
            let subject = verifier(settlement: StubSettlement(receipt: bad))
            let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
            await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
                _ = try await subject.verify(cred, now: now)
            }
        }
    }

    @Test("an auto-memo bound to a different challenge is rejected")
    func memoChallengeMismatch() async throws {
        let foreignMemo = Attribution.encode(serverId: realm, challengeId: "other-challenge")
        let subject = try verifier(settlement: StubSettlement(receipt: receipt(memo: foreignMemo)))
        let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
            _ = try await subject.verify(cred, now: now)
        }
    }

    @Test("among transfers with identical financials, the one bearing the right memo settles")
    func multipleTransfersOneMatchingMemoSettles() async throws {
        // The first log carries a foreign memo, a later one the challenge-bound memo. Scanning all
        // logs (not just the first financial match) still settles -- the 0001 robustness fix.
        let foreign = Attribution.encode(serverId: realm, challengeId: "other-challenge")
        let subject = try verifier(
            settlement: StubSettlement(receipt: receipt(memos: [foreign, memo()]))
        )
        let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
        let receipt = try await subject.verify(cred, now: now)
        #expect(receipt.reference == Self.txHash)
    }

    @Test("a transaction credential whose signature is not hex is rejected as malformed")
    func malformedSignatureRejected() async throws {
        let subject = try verifier(settlement: StubSettlement(receipt: nil, broadcast: receipt()))
        let cred = try credential(
            chargeChallenge(), type: "transaction", field: ("signature", "0xZZ")
        )
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.malformedSignature) {
            _ = try await subject.verify(cred, now: now)
        }
    }

    @Test("a server-pinned memo must match exactly")
    func pinnedMemo() async throws {
        let pinned = Data(repeating: 0xCD, count: 32)
        let matching = try verifier(settlement: StubSettlement(receipt: receipt(memo: pinned)))
        let cred = try credential(
            chargeChallenge(pinnedMemo: pinned.hexPrefixed), type: "hash", field: (
                "hash",
                Self.txHash
            )
        )
        _ = try await matching.verify(cred, now: now) // matches

        let wrong = try verifier(settlement: StubSettlement(receipt: receipt(memo: pinned)))
        let credWrongPin = try credential(
            chargeChallenge(pinnedMemo: Data(repeating: 0xEE, count: 32).hexPrefixed),
            type: "hash", field: ("hash", Self.txHash)
        )
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
            _ = try await wrong.verify(credWrongPin, now: now)
        }
    }

    @Test("a transaction hash settles only once (single-use)")
    func singleUse() async throws {
        let store = InMemoryReplayStore()
        let subject = try verifier(
            settlement: StubSettlement(receipt: receipt()),
            replayStore: store
        )
        let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
        _ = try await subject.verify(cred, now: now) // first settles
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
            _ = try await subject.verify(cred, now: now) // second is rejected
        }
    }

    @Test("a hash naming a transaction not on-chain is rejected")
    func transactionNotFound() async throws {
        let subject = verifier(settlement: StubSettlement(receipt: nil))
        let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
            _ = try await subject.verify(cred, now: now)
        }
    }

    @Test("a receipt for a different transaction than the named hash is rejected")
    func receiptHashMismatchRejected() async throws {
        // The RPC returns a (valid, matching-transfer) receipt, but for a DIFFERENT tx hash than
        // the credential named: it must not settle the named charge.
        let other = try receipt(hash: "0xC0FFEE")
        let subject = try verifier(settlement: StubSettlement(receipt: other))
        let cred = try credential(chargeChallenge(), type: "hash", field: ("hash", Self.txHash))
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.receiptHashMismatch) {
            _ = try await subject.verify(cred, now: now)
        }
    }

    @Test("an unsupported credential type is rejected")
    func unsupportedType() async throws {
        let subject = try verifier(settlement: StubSettlement(receipt: receipt()))
        let cred = try credential(chargeChallenge(), type: "bogus", field: ("hash", Self.txHash))
        await #expect(throws: TempoSettledChargeVerifier.VerifyError.self) {
            _ = try await subject.verify(cred, now: now)
        }
    }

    // MARK: transaction mode

    @Test("a transaction credential broadcasts, then settles on the mined receipt")
    func transactionCredentialBroadcastsAndSettles() async throws {
        let stub = try StubSettlement(receipt: nil, broadcast: receipt())
        let subject = verifier(settlement: stub)
        let cred = try credential(
            chargeChallenge(),
            type: "transaction",
            field: ("signature", "0xdeadbeef")
        )
        let receipt = try await subject.verify(cred, now: now)
        #expect(receipt.reference == Self.txHash)
        #expect(stub.broadcasted == Data(hexPrefixed: "0xdeadbeef"))
    }
}

/// A stub ``TempoChargeSettlement`` that returns configured receipts and records a broadcast.
private final class StubSettlement: TempoChargeSettlement, @unchecked Sendable {
    private let receiptResult: TransactionReceipt?
    private let broadcastResult: TransactionReceipt?
    private let lock = NSLock()
    private var raw: Data?
    var broadcasted: Data? {
        lock.withLock { raw }
    }

    init(receipt: TransactionReceipt?, broadcast: TransactionReceipt? = nil) {
        receiptResult = receipt
        broadcastResult = broadcast
    }

    func receipt(forTransactionHash _: String) async throws -> TransactionReceipt? {
        receiptResult
    }

    func broadcast(_ rawTransaction: Data) async throws -> TransactionReceipt {
        lock.withLock { raw = rawTransaction }
        guard let broadcastResult else {
            throw TempoBroadcastError.reverted("no broadcast result configured")
        }
        return broadcastResult
    }
}

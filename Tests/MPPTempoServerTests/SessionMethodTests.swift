import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo
import Testing
@testable import MPPTempoServer

// SessionMethod over an injected stub provider + in-memory store, matching the
// reference SDK's session-server cases: voucher accept / idempotent-still-charges /
// strictly-increasing / below-settled / exceeds-deposit / bad-signature / closed /
// insufficient-balance, plus open (validate + create), topUp, and close (settle).
/// A configurable stub provider: returns a fixed on-chain snapshot and records the
/// settle / broadcast calls. File-scope so the suite body stays under the cap.
private final class StubProvider: ChannelStateProvider, @unchecked Sendable {
    var onChain: OnChainChannel
    private(set) var settleCalls = 0
    private(set) var openCalls = 0
    init(_ onChain: OnChainChannel) {
        self.onChain = onChain
    }

    func channelState(
        channelID _: Data, escrow _: EthereumAddress, chainID _: UInt64
    ) async -> OnChainChannel {
        onChain
    }

    func broadcastOpen(
        serializedTransaction _: Data, channelID _: Data, escrow _: EthereumAddress,
        chainID _: UInt64
    ) async -> (state: OnChainChannel, txHash: String) {
        openCalls += 1
        return (onChain, "0xopen")
    }

    func broadcastTopUp(
        serializedTransaction _: Data, channelID _: Data, escrow _: EthereumAddress,
        chainID _: UInt64
    ) async -> (state: OnChainChannel, txHash: String) {
        (onChain, "0xtopup")
    }

    func settle(
        channelID _: Data, voucher _: Voucher, escrow _: EthereumAddress, chainID _: UInt64
    ) async -> String {
        settleCalls += 1
        return "0xsettle"
    }
}

@Suite("SessionMethod")
struct SessionMethodTests {
    // Signer key=1 -> address 0x7E5F...Bdf, the channel's authorized signer.
    private let escrow = tempoTestAddress("0x5555555555555555555555555555555555555555")
    private let payee = tempoTestAddress("0x2222222222222222222222222222222222222222")
    private let token = tempoTestAddress("0x3333333333333333333333333333333333333333")
    private let channelID = Data(repeating: 0xAB, count: 32)
    private let chainID: UInt64 = 42431
    private let now = Date(timeIntervalSince1970: 1_767_312_000)

    private let authorizedSigner = tempoTestAddress("0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")

    private func onChainChannel(
        deposit: UInt64 = 1000, settled: UInt64 = 0, finalized: Bool = false,
        closeRequestedAt: UInt64 = 0
    ) -> OnChainChannel {
        OnChainChannel(
            payer: payee, payee: payee, token: token, authorizedSigner: authorizedSigner,
            deposit: ChannelAmount(deposit), settled: ChannelAmount(settled),
            finalized: finalized, closeRequestedAt: closeRequestedAt
        )
    }

    /// Seeds the store with an open channel whose highest accepted voucher is `highest`.
    private func seedStore(
        highest: UInt64,
        spent: UInt64 = 0
    ) async throws -> InMemoryChannelStore {
        let store = InMemoryChannelStore()
        _ = try await store.update(channelID) { _ in
            ChannelState(
                channelID: channelID, chainID: chainID, escrowContract: escrow,
                payer: payee, payee: payee, token: token, authorizedSigner: authorizedSigner,
                deposit: ChannelAmount(1000), highestVoucherAmount: ChannelAmount(highest),
                spent: ChannelAmount(spent)
            )
        }
        return store
    }

    private func sessionChallenge(amount: String = "1") throws -> Challenge {
        let request = EncodedJSON(json: .object([
            "amount": .string(amount),
            "recipient": .string("0x2222222222222222222222222222222222222222"),
            "currency": .string("0x3333333333333333333333333333333333333333"),
            "methodDetails": .object([
                "chainId": .integer(Int64(chainID)),
                "escrowContract": .string("0x5555555555555555555555555555555555555555"),
            ]),
        ]))
        return try Challenge(
            id: "session-1", realm: "https://api.example.com",
            method: MethodName("tempo"), intent: .session, request: request
        )
    }

    private func hex(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }
            .joined()
    }

    /// A voucher-action credential signed by key=1 over `cumulative`.
    private func voucherCredential(
        cumulative: String, action: String = "voucher", amount: String = "1"
    ) throws -> Credential {
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: cumulative))
        let signature = try voucher.sign(
            escrowContract: escrow,
            chainId: chainID,
            with: signer(byte: 1)
        )
        return try Credential(
            challenge: sessionChallenge(amount: amount), source: nil,
            payload: [
                "action": .string(action),
                "channelId": .string(hex(channelID)),
                "cumulativeAmount": .string(cumulative),
                "signature": .string(hex(signature)),
            ]
        )
    }

    private func method(_ store: InMemoryChannelStore, _ provider: StubProvider) -> SessionMethod {
        SessionMethod(provider: provider, store: store, defaultChainID: chainID)
    }

    @Test("supports tempo/session, not tempo/charge")
    func supports() throws {
        let session = method(InMemoryChannelStore(), StubProvider(onChainChannel()))
        #expect(try session.supports(sessionChallenge()))
        let charge = try Challenge(
            id: "c", realm: "https://api.example.com", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("e30")
        )
        #expect(!session.supports(charge))
    }

    @Test("a valid voucher advances the highest and charges one unit")
    func voucherAccepts() async throws {
        let store = try await seedStore(highest: 0)
        let session = method(store, StubProvider(onChainChannel(deposit: 1000)))
        let receipt = try await session.verify(
            voucherCredential(cumulative: "100", amount: "10"),
            now: now
        )
        #expect(receipt.extras["intent"] == "session")
        #expect(receipt.extras["acceptedCumulative"] == "100")
        #expect(receipt.extras["spent"] == "10") // charged this request's amount
        #expect(receipt.extras["units"] == "1")
        #expect(receipt.reference == hex(channelID))
        let channel = await store.channel(channelID)
        #expect(channel?.highestVoucherAmount == ChannelAmount(100))
    }

    @Test("an equal-cumulative replay does not advance the highest but still charges")
    func voucherIdempotentStillCharges() async throws {
        let store = try await seedStore(highest: 100, spent: 0)
        let session = method(store, StubProvider(onChainChannel(deposit: 1000)))
        let receipt = try await session.verify(
            voucherCredential(cumulative: "100", amount: "5"),
            now: now
        )
        #expect(receipt.extras["acceptedCumulative"] == "100") // unchanged
        #expect(receipt.extras["spent"] == "5") // still charged
        #expect(receipt.extras["units"] == "1")
    }

    @Test("a voucher below the highest accepted is rejected")
    func voucherBelowHighest() async throws {
        let store = try await seedStore(highest: 200)
        let session = method(store, StubProvider(onChainChannel(deposit: 1000)))
        await #expect(throws: SessionMethod.SessionError.belowHighestVoucher) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a voucher at/below the on-chain settled amount is rejected")
    func voucherBelowSettled() async throws {
        let store = try await seedStore(highest: 0)
        let session = method(store, StubProvider(onChainChannel(deposit: 1000, settled: 100)))
        await #expect(throws: SessionMethod.SessionError.belowSettled) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a voucher exceeding the on-chain deposit is rejected")
    func voucherExceedsDeposit() async throws {
        let store = try await seedStore(highest: 0)
        let session = method(store, StubProvider(onChainChannel(deposit: 50)))
        await #expect(throws: SessionMethod.SessionError.exceedsDeposit) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a voucher signed by the wrong key is rejected")
    func voucherBadSignature() async throws {
        let store = try await seedStore(highest: 0)
        let session = method(store, StubProvider(onChainChannel(deposit: 1000)))
        // Sign with key=2; the channel's authorized signer is key=1.
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "100"))
        let wrongSigner =
            try signer(byte: 2)
        let signature = try voucher.sign(
            escrowContract: escrow,
            chainId: chainID,
            with: wrongSigner
        )
        let credential = try Credential(
            challenge: sessionChallenge(), source: nil,
            payload: [
                "action": .string("voucher"), "channelId": .string(hex(channelID)),
                "cumulativeAmount": .string("100"), "signature": .string(hex(signature)),
            ]
        )
        await #expect(throws: SessionMethod.SessionError.invalidVoucherSignature) {
            try await session.verify(credential, now: now)
        }
    }

    @Test("a voucher on a finalized channel is rejected as closed")
    func voucherClosed() async throws {
        let store = try await seedStore(highest: 0)
        let session = method(store, StubProvider(onChainChannel(deposit: 1000, finalized: true)))
        await #expect(throws: SessionMethod.SessionError.self) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a request that overdraws the available balance is rejected")
    func voucherInsufficientBalance() async throws {
        // highest 100, already spent 100 -> available 0; a charge of 10 overdraws.
        let store = try await seedStore(highest: 100, spent: 100)
        let session = method(store, StubProvider(onChainChannel(deposit: 1000)))
        await #expect(throws: SessionMethod.SessionError.insufficientBalance) {
            try await session.verify(voucherCredential(cumulative: "100", amount: "10"), now: now)
        }
    }

    @Test("open validates the on-chain channel, creates the store record, and charges")
    func openCreates() async throws {
        let store = InMemoryChannelStore() // no record yet
        let provider = StubProvider(onChainChannel(deposit: 1000))
        let session = method(store, provider)
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "100"))
        let signature = try voucher.sign(
            escrowContract: escrow,
            chainId: chainID,
            with: signer(byte: 1)
        )
        let credential = try Credential(
            challenge: sessionChallenge(amount: "10"), source: nil,
            payload: [
                "action": .string("open"), "channelId": .string(hex(channelID)),
                "cumulativeAmount": .string("100"), "signature": .string(hex(signature)),
                "transaction": .string("0xdeadbeef"),
            ]
        )
        let receipt = try await session.verify(credential, now: now)
        #expect(provider.openCalls == 1)
        #expect(receipt.extras["acceptedCumulative"] == "100")
        #expect(receipt.extras["spent"] == "10")
        let channel = await store.channel(channelID)
        #expect(channel?.highestVoucherAmount == ChannelAmount(100))
        #expect(channel?.authorizedSigner == authorizedSigner)
    }

    @Test("topUp refreshes the recorded deposit from the broadcast result")
    func topUpRefreshesDeposit() async throws {
        let store = try await seedStore(highest: 100)
        let provider = StubProvider(onChainChannel(deposit: 5000)) // deposit after top-up
        let session = method(store, provider)
        let credential = try Credential(
            challenge: sessionChallenge(), source: nil,
            payload: [
                "action": .string("topUp"), "channelId": .string(hex(channelID)),
                "additionalDeposit": .string("4000"), "transaction": .string("0xfeed"),
            ]
        )
        let receipt = try await session.verify(credential, now: now)
        #expect(receipt.extras["txHash"] == "0xtopup")
        let channel = await store.channel(channelID)
        #expect(channel?.deposit == ChannelAmount(5000))
    }

    @Test("close settles the highest voucher on-chain and finalizes the channel")
    func closeSettles() async throws {
        let store = try await seedStore(highest: 100, spent: 40)
        let provider = StubProvider(onChainChannel(deposit: 1000))
        let session = method(store, provider)
        let receipt = try await session.verify(
            voucherCredential(cumulative: "100", action: "close"),
            now: now
        )
        #expect(provider.settleCalls == 1)
        #expect(receipt.extras["txHash"] == "0xsettle")
        let channel = await store.channel(channelID)
        #expect(channel?.finalized == true)
    }
}

import Foundation
import MPPEVM
import MPPTempo
import Testing
@testable import MPPTempoServer

// Off-chain channel accounting: deductFromChannel atomically draws against the
// available balance (highestVoucherAmount - spent), advancing spent/units, and
// fails closed on an unknown / finalized / closing channel or an over-draw.
@Suite("ChannelStore")
struct ChannelStoreTests {
    private let channelID = Data(repeating: 0xAB, count: 32)

    private func address(_ byte: UInt8) -> EthereumAddress {
        guard let address = EthereumAddress(bytes: Data(repeating: byte, count: 20)) else {
            preconditionFailure("20 bytes is a valid address")
        }
        return address
    }

    /// Seeds the channel with a highest accepted voucher of `highest`.
    private func seed(
        _ store: InMemoryChannelStore,
        highest: ChannelAmount,
        finalized: Bool = false,
        closing: Bool = false
    ) async throws {
        _ = try await store.update(channelID) { _ in
            ChannelState(
                channelID: channelID, chainID: 42431, escrowContract: address(5),
                payer: address(1), payee: address(2), token: address(3),
                authorizedSigner: address(4), deposit: ChannelAmount(1000),
                highestVoucherAmount: highest, finalized: finalized, closing: closing
            )
        }
    }

    @Test("deduct advances spent/units and reduces the available balance")
    func deductSucceeds() async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: ChannelAmount(100))

        let first = try await deductFromChannel(
            store,
            channelID: channelID,
            amount: ChannelAmount(30)
        )
        #expect(first.spent == ChannelAmount(30))
        #expect(first.units == 1)
        #expect(first.available == ChannelAmount(70))

        let second = try await deductFromChannel(
            store,
            channelID: channelID,
            amount: ChannelAmount(70)
        )
        #expect(second.spent == ChannelAmount(100))
        #expect(second.units == 2)
        #expect(second.available == .zero)
    }

    @Test("a draw beyond the available balance throws insufficientBalance")
    func insufficient() async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: ChannelAmount(50))
        await #expect(throws: ChannelError.self) {
            try await deductFromChannel(store, channelID: channelID, amount: ChannelAmount(51))
        }
        // The failed draw left the channel unchanged.
        let state = await store.channel(channelID)
        #expect(state?.spent == .zero)
        #expect(state?.units == 0)
    }

    @Test("a draw on an unknown channel throws notFound")
    func notFound() async {
        let store = InMemoryChannelStore()
        await #expect(throws: ChannelError.notFound) {
            try await deductFromChannel(store, channelID: channelID, amount: ChannelAmount(1))
        }
    }

    @Test("a draw on a finalized or closing channel throws closed", arguments: [
        (finalized: true, closing: false),
        (finalized: false, closing: true),
    ])
    func closed(finalized: Bool, closing: Bool) async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: ChannelAmount(100), finalized: finalized, closing: closing)
        await #expect(throws: ChannelError.self) {
            try await deductFromChannel(store, channelID: channelID, amount: ChannelAmount(1))
        }
    }

    @Test("concurrent draws are atomic: exactly the affordable number succeed")
    func concurrentAtomic() async throws {
        let store = InMemoryChannelStore()
        try await seed(store, highest: ChannelAmount(10)) // affords ten draws of 1
        let attempts = 16
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< attempts {
                group.addTask {
                    let drawn = try? await deductFromChannel(
                        store, channelID: channelID, amount: ChannelAmount(1)
                    )
                    return drawn != nil
                }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        // The actor serializes update, so the counters never over-draw.
        #expect(wins == 10)
        let final = await store.channel(channelID)
        #expect(final?.spent == ChannelAmount(10))
        #expect(final?.units == 10)
    }
}

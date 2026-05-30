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
// The StubProvider/Flag doubles and the shared session fixtures (escrow, seedStore,
// voucherCredential, sessionMethod, ...) live in TempoServerTestSupport.swift.

@Suite("SessionMethod")
struct SessionMethodTests {
    @Test("supports tempo/session, not tempo/charge")
    func supports() throws {
        let session = sessionMethod(InMemoryChannelStore(), StubProvider(onChainChannel()))
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
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        let receipt = try await session.verify(
            voucherCredential(cumulative: "100", amount: "10"),
            now: now
        )
        #expect(receipt.extras["intent"] == .string("session"))
        #expect(receipt.extras["acceptedCumulative"] == .string("100"))
        #expect(receipt.extras["spent"] == .string("10")) // charged this request's amount
        #expect(receipt.extras["units"] == .uint(1))
        #expect(receipt.reference == hex(channelID))
        let channel = await store.channel(channelID)
        #expect(channel?.highestVoucherAmount == ChannelAmount(100))
    }

    @Test("an equal-cumulative replay does not advance the highest but still charges")
    func voucherIdempotentStillCharges() async throws {
        let store = try await seedStore(highest: 100, spent: 0)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        let receipt = try await session.verify(
            voucherCredential(cumulative: "100", amount: "5"),
            now: now
        )
        #expect(receipt.extras["acceptedCumulative"] == .string("100")) // unchanged
        #expect(receipt.extras["spent"] == .string("5")) // still charged
        #expect(receipt.extras["units"] == .uint(1))
    }

    @Test("a charge amount that overflows uint128 is rejected, not charged as zero")
    func overflowAmountFailsClosed() async throws {
        let store = try await seedStore(highest: 0)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        // 40 nines exceeds uint128 max: a canonical Amount but not a ChannelAmount;
        // must reject (fail closed), never silently charge zero.
        await #expect(throws: SessionMethod.SessionError.self) {
            try await session.verify(
                voucherCredential(cumulative: "100", amount: String(repeating: "9", count: 40)),
                now: now
            )
        }
    }

    @Test("a voucher below the highest accepted is rejected")
    func voucherBelowHighest() async throws {
        let store = try await seedStore(highest: 200)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        await #expect(throws: SessionMethod.SessionError.belowHighestVoucher) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a voucher at/below the on-chain settled amount is rejected")
    func voucherBelowSettled() async throws {
        let store = try await seedStore(highest: 0)
        let session = sessionMethod(
            store,
            StubProvider(onChainChannel(deposit: 1000, settled: 100))
        )
        await #expect(throws: SessionMethod.SessionError.belowSettled) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a voucher exceeding the on-chain deposit is rejected")
    func voucherExceedsDeposit() async throws {
        let store = try await seedStore(highest: 0)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 50)))
        await #expect(throws: SessionMethod.SessionError.exceedsDeposit) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a voucher signed by the wrong key is rejected")
    func voucherBadSignature() async throws {
        let store = try await seedStore(highest: 0)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
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
        let session = sessionMethod(
            store,
            StubProvider(onChainChannel(deposit: 1000, finalized: true))
        )
        await #expect(throws: SessionMethod.SessionError.self) {
            try await session.verify(voucherCredential(cumulative: "100"), now: now)
        }
    }

    @Test("a request that overdraws the available balance is rejected")
    func voucherInsufficientBalance() async throws {
        // highest 100, already spent 100 -> available 0; a charge of 10 overdraws.
        let store = try await seedStore(highest: 100, spent: 100)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        await #expect(throws: SessionMethod.SessionError.insufficientBalance) {
            try await session.verify(voucherCredential(cumulative: "100", amount: "10"), now: now)
        }
    }

    @Test("open validates the on-chain channel, creates the store record, and charges")
    func openCreates() async throws {
        let store = InMemoryChannelStore() // no record yet
        let provider = StubProvider(onChainChannel(deposit: 1000))
        let session = sessionMethod(store, provider)
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
        #expect(receipt.extras["acceptedCumulative"] == .string("100"))
        #expect(receipt.extras["spent"] == .string("10"))
        let channel = await store.channel(channelID)
        #expect(channel?.highestVoucherAmount == ChannelAmount(100))
        #expect(channel?.authorizedSigner == authorizedSigner)
    }

    @Test("re-open raises spent to a newly-advanced on-chain settled (no overstated balance)")
    func openRaisesSpentToSettled() async throws {
        // Known channel: highest 500, spent 0. The chain then settled 300 externally.
        let store = try await seedStore(highest: 500, spent: 0)
        let session = sessionMethod(
            store,
            StubProvider(onChainChannel(deposit: 2000, settled: 300))
        )
        let voucher = try #require(Voucher(channelID: channelID, cumulativeAmount: "1000"))
        let signature = try voucher.sign(
            escrowContract: escrow,
            chainId: chainID,
            with: signer(byte: 1)
        )
        _ = try await session.verify(
            Credential(challenge: sessionChallenge(amount: "10"), source: nil, payload: [
                "action": .string("open"), "channelId": .string(hex(channelID)),
                "cumulativeAmount": .string("1000"), "signature": .string(hex(signature)),
                "transaction": .string("0xdead"),
            ]), now: now
        )
        // spent raised to settled (300) before the open's own charge (10) -> 310.
        let channel = await store.channel(channelID)
        #expect(channel?.spent == ChannelAmount(310))
        #expect(channel?.settledOnChain == ChannelAmount(300))
    }
}

@Suite("SessionMethod close/topUp")
struct SessionMethodCloseTests {
    @Test("topUp refreshes the recorded deposit from the broadcast result")
    func topUpRefreshesDeposit() async throws {
        let store = try await seedStore(highest: 100)
        let provider = StubProvider(onChainChannel(deposit: 5000)) // deposit after top-up
        let session = sessionMethod(store, provider)
        let credential = try Credential(
            challenge: sessionChallenge(), source: nil,
            payload: [
                "action": .string("topUp"), "channelId": .string(hex(channelID)),
                "additionalDeposit": .string("4000"), "transaction": .string("0xfeed"),
            ]
        )
        let receipt = try await session.verify(credential, now: now)
        #expect(receipt.extras["txHash"] == .string("0xtopup"))
        let channel = await store.channel(channelID)
        #expect(channel?.deposit == ChannelAmount(5000))
    }

    @Test("close settles the highest voucher on-chain and finalizes the channel")
    func closeSettles() async throws {
        let store = try await seedStore(highest: 100, spent: 40)
        let provider = StubProvider(onChainChannel(deposit: 1000))
        let session = sessionMethod(store, provider)
        let receipt = try await session.verify(
            voucherCredential(cumulative: "100", action: "close"),
            now: now
        )
        #expect(provider.settleCalls == 1)
        #expect(provider.settledCumulative == "100")
        #expect(receipt.extras["txHash"] == .string("0xsettle"))
        let channel = await store.channel(channelID)
        #expect(channel?.finalized == true)
    }

    @Test("close with a lower client voucher settles the stored highest, never underpays")
    func closeNeverUnderpays() async throws {
        // Server drew up to highest=100; a malicious payer sends a validly self-signed
        // close voucher for cumulative=1. Settlement must use the stored 100, not 1.
        let store = try await seedStore(highest: 100, spent: 100)
        let provider = StubProvider(onChainChannel(deposit: 1000))
        let session = sessionMethod(store, provider)
        let receipt = try await session.verify(
            voucherCredential(cumulative: "1", action: "close"),
            now: now
        )
        #expect(provider.settleCalls == 1)
        #expect(provider.settledCumulative == "100")
        let channel = await store.channel(channelID)
        #expect(channel?.finalized == true)
        #expect(channel?.settledOnChain == ChannelAmount(100))
        #expect(receipt.extras["txHash"] == .string("0xsettle"))
    }

    @Test("close sets closing before settling, so a concurrent draw is rejected mid-settle")
    func closeBlocksConcurrentDrawDuringSettle() async throws {
        let store = try await seedStore(highest: 100, spent: 0)
        let provider = StubProvider(onChainChannel(deposit: 1000))
        // During the on-chain settle window, a concurrent charge must be rejected
        // because close has already marked the channel closing.
        let drawDuringSettleClosed = Flag(false)
        provider.onSettle = { @Sendable in
            do {
                _ = try await deductFromChannel(
                    store,
                    channelID: channelID,
                    amount: ChannelAmount(10)
                )
            } catch let error as ChannelError {
                if case .closed = error { drawDuringSettleClosed.set(true) }
            } catch {}
        }
        let session = sessionMethod(store, provider)
        _ = try await session.verify(
            voucherCredential(cumulative: "100", action: "close"), now: now
        )
        #expect(drawDuringSettleClosed.get() == true)
    }

    @Test("a second concurrent close is rejected mid-settle (single-flight, no duplicate settle)")
    func concurrentCloseRejected() async throws {
        let store = try await seedStore(highest: 100, spent: 0)
        let provider = StubProvider(onChainChannel(deposit: 1000))
        let session = sessionMethod(store, provider)
        // While the first close is settling on-chain, a second close must be rejected
        // (the channel is already closing) so settle is never broadcast twice.
        let secondCloseRejected = Flag(false)
        provider.onSettle = { @Sendable in
            do {
                _ = try await session.verify(
                    voucherCredential(cumulative: "100", action: "close"), now: now
                )
            } catch let error as SessionMethod.SessionError {
                if case .channelClosed = error { secondCloseRejected.set(true) }
            } catch {}
        }
        _ = try await session.verify(
            voucherCredential(cumulative: "100", action: "close"), now: now
        )
        #expect(secondCloseRejected.get() == true)
        #expect(provider.settleCalls == 1)
    }

    @Test("a voucher racing a close cannot advance the stored highest")
    func voucherOnClosingChannelRejected() async throws {
        let store = try await seedStore(highest: 100, spent: 0)
        _ = try await store.update(channelID) { current in
            guard var channel = current else { return current }
            channel.closing = true
            return channel
        }
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        await #expect(throws: SessionMethod.SessionError.channelClosed(reason: "closing")) {
            try await session.verify(voucherCredential(cumulative: "200"), now: now)
        }
        // The racing voucher must not have advanced the off-chain highest.
        let channel = await store.channel(channelID)
        #expect(channel?.highestVoucherAmount == ChannelAmount(100))
    }

    @Test("close on an already-finalized channel is rejected")
    func closeFinalizedRejected() async throws {
        let store = try await seedStore(highest: 100, spent: 40)
        _ = try await store.update(channelID) { current in
            guard var channel = current else { return current }
            channel.finalized = true
            return channel
        }
        let provider = StubProvider(onChainChannel(deposit: 1000))
        let session = sessionMethod(store, provider)
        await #expect(throws: SessionMethod.SessionError.channelClosed(reason: "finalized")) {
            try await session.verify(
                voucherCredential(cumulative: "100", action: "close"), now: now
            )
        }
        #expect(provider.settleCalls == 0)
    }
}

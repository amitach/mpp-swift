import Foundation
import MPPCore
import MPPEVM
import MPPTempo
import Testing
@testable import MPPTempoServer

// Per-challenge `methodDetails.minVoucherDelta` override (audit DELTA-TEST): a challenge can set a
// minimum increment between vouchers that overrides the verifier's static default, and a malformed
// override fails closed. Fixtures live in TempoServerTestSupport.swift.
@Suite("SessionMethod minVoucherDelta")
struct SessionMethodDeltaTests {
    @Test("a per-challenge minVoucherDelta rejects a voucher whose delta is below it (DELTA-TEST)")
    func voucherDeltaBelowPerChallengeMin() async throws {
        let store = try await seedStore(highest: 100)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        // The verifier's static default is zero (delta 20 would be accepted); the challenge's
        // methodDetails.minVoucherDelta=50 overrides it, so this voucher is rejected.
        await #expect(throws: SessionMethod.SessionError.deltaTooSmall) {
            try await session.verify(
                voucherCredential(cumulative: "120", minVoucherDelta: "50"), now: now
            )
        }
    }

    @Test("a voucher meeting the per-challenge minVoucherDelta is accepted")
    func voucherDeltaMeetsPerChallengeMin() async throws {
        let store = try await seedStore(highest: 100)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        _ = try await session.verify(
            voucherCredential(cumulative: "200", minVoucherDelta: "50"), now: now
        )
        let channel = await store.channel(channelID)
        #expect(channel?.highestVoucherAmount == ChannelAmount(200)) // delta 100 >= 50: advanced
    }

    @Test("a malformed per-challenge minVoucherDelta fails closed for a voucher")
    func voucherMalformedMinDelta() async throws {
        let store = try await seedStore(highest: 100)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        await #expect(throws: SessionMethod.SessionError.malformedRequest) {
            try await session.verify(
                voucherCredential(cumulative: "200", minVoucherDelta: "not-a-number"), now: now
            )
        }
    }

    @Test("a malformed minVoucherDelta does not block a close (the delta gates vouchers only)")
    func malformedMinDeltaAllowsClose() async throws {
        let store = try await seedStore(highest: 100, spent: 40)
        let session = sessionMethod(store, StubProvider(onChainChannel(deposit: 1000)))
        // Close never reads the delta, so a typo'd override must not block settlement (funds
        // recovery): the close succeeds and finalizes the channel.
        _ = try await session.verify(
            voucherCredential(cumulative: "100", action: "close", minVoucherDelta: "not-a-number"),
            now: now
        )
        let channel = await store.channel(channelID)
        #expect(channel?.finalized == true)
    }
}

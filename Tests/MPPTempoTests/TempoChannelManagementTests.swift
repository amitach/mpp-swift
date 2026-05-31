import Foundation
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// Client-initiated channel management on TempoChannelMethod: topUp (a signed [approve, topUp]
// tx the server relays) and close (a signed voucher the server settles on-chain). These are
// not 402 charge responses, so they are explicit methods taking the session challenge plus
// their parameters; both resolve the open channel from the registry. Hermetic: a stub open
// builder opens the channel first, a stub topUp builder stands in for the FFI.
@Suite("TempoChannelMethod management")
struct TempoChannelManagementTests {
    @Test("buildTopUp emits a topUp payload with the open channel's id and the relay tx")
    func topUpBuildsCredential() async throws {
        let openBuilder = StubOpenTxBuilder()
        let topUp = StubTopUpTxBuilder()
        let method = try makeMethod(builder: openBuilder, topUpBuilder: topUp)
        let opened = try await method.buildCredential(for: sessionChallenge(amount: "100"))
        let channelHex = try #require(jsonString(opened.payload["channelId"]))

        let credential = try await method.buildTopUp(
            for: sessionChallenge(), additionalDeposit: "500"
        )
        #expect(credential.payload["action"] == .string("topUp"))
        #expect(credential.payload["type"] == .string("transaction"))
        #expect(credential.payload["channelId"] == .string(channelHex))
        #expect(credential.payload["additionalDeposit"] == .string("500"))
        #expect(credential.payload["transaction"] == .string(Fixture.topUpTxBytes.hexPrefixed))

        // The builder was handed the open channel's id and the additionalDeposit.
        let calls = await topUp.calls
        #expect(calls.count == 1)
        #expect(calls.first?.channelID == Data(hexPrefixed: channelHex))
        #expect(calls.first?.additionalDeposit == "500")
    }

    @Test("buildClose settles the latest cumulative with a verifying voucher and no tx")
    func closeBuildsVerifyingVoucher() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        let opened = try await method.buildCredential(for: sessionChallenge(amount: "100"))
        _ = try await method.buildCredential(for: sessionChallenge(amount: "200")) // cumulative 300

        let credential = try await method.buildClose(for: sessionChallenge())
        #expect(credential.payload["action"] == .string("close"))
        #expect(credential.payload["cumulativeAmount"] == .string("300"))
        #expect(credential.payload["transaction"] == nil) // close carries no tx; the server settles
        #expect(credential.payload["channelId"] == opened.payload["channelId"])
        #expect(try voucherVerifies(credential.payload, wallet: method.address))
    }

    @Test("close removes the channel: a second close has no open channel")
    func closeRemovesChannel() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder())
        _ = try await method.buildCredential(for: sessionChallenge(amount: "100"))
        _ = try await method.buildClose(for: sessionChallenge())
        await #expect(throws: TempoChannelMethodError.noOpenChannel) {
            _ = try await method.buildClose(for: sessionChallenge())
        }
    }

    @Test("topUp/close without an open channel throw noOpenChannel")
    func managementWithoutOpenChannel() async throws {
        let method = try makeMethod(
            builder: StubOpenTxBuilder(),
            topUpBuilder: StubTopUpTxBuilder()
        )
        await #expect(throws: TempoChannelMethodError.noOpenChannel) {
            _ = try await method.buildTopUp(for: sessionChallenge(), additionalDeposit: "500")
        }
        await #expect(throws: TempoChannelMethodError.noOpenChannel) {
            _ = try await method.buildClose(for: sessionChallenge())
        }
    }

    @Test("topUp without a configured builder throws topUpUnsupported")
    func topUpWithoutBuilder() async throws {
        let method = try makeMethod(builder: StubOpenTxBuilder()) // no topUpBuilder
        _ = try await method.buildCredential(for: sessionChallenge(amount: "100"))
        await #expect(throws: TempoChannelMethodError.topUpUnsupported) {
            _ = try await method.buildTopUp(for: sessionChallenge(), additionalDeposit: "500")
        }
    }

    @Test("management ops reject a wrong method/intent")
    func managementRejectsWrongIntent() async throws {
        let method = try makeMethod(
            builder: StubOpenTxBuilder(),
            topUpBuilder: StubTopUpTxBuilder()
        )
        await #expect(throws: TempoChannelMethodError.wrongMethodOrIntent) {
            _ = try await method.buildClose(for: sessionChallenge(intent: "charge"))
        }
        await #expect(throws: TempoChannelMethodError.wrongMethodOrIntent) {
            _ = try await method.buildTopUp(
                for: sessionChallenge(intent: "charge"), additionalDeposit: "500"
            )
        }
    }
}

import Foundation
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// FU-1: when the challenge suggests a channelId (methodDetails.channelId) and a channel reader
// is configured, TempoChannelMethod attaches to the existing on-chain channel (if it has a
// positive deposit and is not finalized) instead of opening a fresh one - the charge then
// vouchers against it, starting from the on-chain settled amount. A read failure, an unusable
// channel, no reader, or no suggested id all fall through to a normal open.
@Suite("TempoChannelMethod recovery")
struct TempoChannelRecoveryTests {
    @Test("a recoverable suggested channel is attached and vouchered, not re-opened")
    func recoverAttachesAndVouchers() async throws {
        let builder = StubOpenTxBuilder()
        let wallet = try walletAddress()
        let reader = try StubChannelReader(
            recoverableChannel(deposit: 1000, settled: 50, finalized: false, wallet: wallet)
        )
        let recovering = try makeMethod(builder: builder, channelReader: reader)
        let challenge = try sessionChallenge(amount: "100", channelId: Fixture.recoverChannelHex)

        let credential = try await recovering.buildCredential(for: challenge)
        // Vouchered against the recovered channel: cumulative = on-chain settled (50) + 100.
        #expect(credential.payload["action"] == .string("voucher"))
        #expect(credential.payload["cumulativeAmount"] == .string("150"))
        #expect(credential.payload["channelId"] == .string(Fixture.recoverChannelHex))
        #expect(try voucherVerifies(credential.payload, wallet: recovering.address))
        // The reader was consulted with the suggested id; no open was built.
        #expect(await reader.reads == [Data(hexPrefixed: Fixture.recoverChannelHex)])
        #expect(await builder.parameters.isEmpty)
    }

    @Test("a finalized suggested channel is not recovered: the charge opens fresh")
    func finalizedNotRecovered() async throws {
        let builder = StubOpenTxBuilder()
        let reader = try StubChannelReader(
            recoverableChannel(
                deposit: 1000,
                settled: 0,
                finalized: true,
                wallet: walletAddress()
            )
        )
        let method = try makeMethod(builder: builder, channelReader: reader)
        let credential = try await method.buildCredential(
            for: sessionChallenge(channelId: Fixture.recoverChannelHex)
        )
        #expect(credential.payload["action"] == .string("open"))
        #expect(await builder.parameters.count == 1)
    }

    @Test("a zero-deposit suggested channel is not recovered: the charge opens fresh")
    func zeroDepositNotRecovered() async throws {
        let builder = StubOpenTxBuilder()
        let reader = try StubChannelReader(
            recoverableChannel(
                deposit: 0,
                settled: 0,
                finalized: false,
                wallet: walletAddress()
            )
        )
        let method = try makeMethod(builder: builder, channelReader: reader)
        let credential = try await method.buildCredential(
            for: sessionChallenge(channelId: Fixture.recoverChannelHex)
        )
        #expect(credential.payload["action"] == .string("open"))
        #expect(await builder.parameters.count == 1)
    }

    @Test("a read failure falls through to a normal open")
    func readFailureOpensFresh() async throws {
        let builder = StubOpenTxBuilder()
        let method = try makeMethod(
            builder: builder,
            channelReader: StubChannelReader(failure: StubError.boom)
        )
        let credential = try await method.buildCredential(
            for: sessionChallenge(channelId: Fixture.recoverChannelHex)
        )
        #expect(credential.payload["action"] == .string("open"))
        #expect(await builder.parameters.count == 1)
    }

    @Test("no reader, or no suggested channelId, means no recovery (opens fresh)")
    func noRecoveryWithoutReaderOrId() async throws {
        // Suggested id but no reader.
        let noReaderMethod = try makeMethod(builder: StubOpenTxBuilder())
        let noReader = try await noReaderMethod
            .buildCredential(for: sessionChallenge(channelId: Fixture.recoverChannelHex))
        #expect(noReader.payload["action"] == .string("open"))

        // Reader but no suggested id: the reader is never consulted.
        let reader = try StubChannelReader(
            recoverableChannel(deposit: 1000, settled: 0, finalized: false, wallet: walletAddress())
        )
        let noIdMethod = try makeMethod(builder: StubOpenTxBuilder(), channelReader: reader)
        let noId = try await noIdMethod.buildCredential(for: sessionChallenge())
        #expect(noId.payload["action"] == .string("open"))
        #expect(await reader.reads.isEmpty)
    }

    private func walletAddress() throws -> EthereumAddress {
        try #require(EthereumAddress(uncompressedPublicKey: makeSigner().publicKey))
    }
}

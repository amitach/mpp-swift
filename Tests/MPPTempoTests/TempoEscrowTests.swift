import Foundation
import MPPClient
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

// TempoEscrow getChannel: call-data encoding and return decoding against a known
// ABI blob and a stubbed RPC, plus a network-gated read of the real Moderato escrow
// (skipped unless MPP_MODERATO_E2E=1). StubHTTP/makeURL/makeAddress are shared.

/// Left-pads `bytes` to a 32-byte ABI word (statics are right-aligned).
private func word(_ bytes: Data) -> Data {
    Data(repeating: 0, count: 32 - bytes.count) + bytes
}

private func u64BE(_ value: UInt64) -> Data {
    var big = value.bigEndian
    return Data(bytes: &big, count: 8)
}

/// An eight-word getChannel return: finalized, closeRequestedAt, payer, payee,
/// token, authorizedSigner, deposit, settled.
private func channelBlob() -> Data {
    word(Data([0x01])) // finalized = true
        + word(u64BE(0x1234)) // closeRequestedAt
        + word(Data(repeating: 0x11, count: 20)) // payer
        + word(Data(repeating: 0x22, count: 20)) // payee
        + word(Data(repeating: 0x33, count: 20)) // token
        + word(Data(repeating: 0x44, count: 20)) // authorizedSigner
        + word(u64BE(1000)) // deposit
        + word(u64BE(300)) // settled
}

@Suite("TempoEscrow")
struct TempoEscrowTests {
    @Test("getChannel call data is the selector followed by the 32-byte channel id")
    func callData() throws {
        let channelID = Data(repeating: 0xAB, count: 32)
        let data = try #require(TempoEscrow.getChannelCallData(channelID: channelID))
        #expect(data.count == 36)
        #expect(data.prefix(4) == TempoEscrow.getChannelSelector)
        #expect(Data(data.suffix(32)) == channelID)
    }

    @Test("getChannel call data is nil for a channel id that is not 32 bytes")
    func callDataWrongLength() {
        #expect(TempoEscrow.getChannelCallData(channelID: Data(repeating: 0, count: 31)) == nil)
    }

    @Test("decodeChannel maps the eight ABI words to the channel fields")
    func decode() throws {
        let channel = try #require(TempoEscrow.decodeChannel(channelBlob()))
        #expect(channel.finalized == true)
        #expect(channel.closeRequestedAt == 0x1234)
        #expect(channel.payer == makeAddress("0x" + String(repeating: "11", count: 20)))
        #expect(channel.payee == makeAddress("0x" + String(repeating: "22", count: 20)))
        #expect(channel.token == makeAddress("0x" + String(repeating: "33", count: 20)))
        #expect(channel.authorizedSigner == makeAddress("0x" + String(repeating: "44", count: 20)))
        #expect(channel.deposit == ChannelAmount(1000))
        #expect(channel.settled == ChannelAmount(300))
    }

    @Test("decodeChannel returns nil for a return shorter than eight words")
    func decodeShort() {
        #expect(TempoEscrow.decodeChannel(Data(repeating: 0, count: 32 * 7)) == nil)
    }

    @Test("readChannel calls the escrow via eth_call and decodes the return")
    func readChannel() async throws {
        let stub =
            StubHTTP(json: #"{"jsonrpc":"2.0","id":1,"result":"\#(channelBlob().hexPrefixed)"}"#)
        let rpc = try EVMRPC(transport: stub, url: makeURL("https://rpc.example.com"))
        let escrow = makeAddress("0x5555555555555555555555555555555555555555")
        let channel = try await TempoEscrow.readChannel(
            Data(repeating: 0xAB, count: 32), escrow: escrow, via: rpc
        )
        #expect(channel.deposit == ChannelAmount(1000))
        #expect(channel.payer == makeAddress("0x" + String(repeating: "11", count: 20)))
        // The eth_call targeted the escrow with the getChannel selector.
        let body = try #require(stub.lastBody)
        guard case let .object(envelope) = try JSONDecoder().decode(JSONValue.self, from: body),
              case let .array(params)? = envelope["params"],
              case let .object(call) = params.first,
              case let .string(callData)? = call["data"]
        else { throw EVMRPCError.malformedResponse("params shape") }
        #expect(callData.hasPrefix(TempoEscrow.getChannelSelector.hexPrefixed))
    }

    @Test("live Moderato getChannel decodes the real escrow", .enabled(if: liveEnabled))
    func liveModeratoGetChannel() async throws {
        let rpc = try EVMRPC(
            transport: URLSessionTransport(),
            url: makeURL("https://rpc.moderato.tempo.xyz")
        )
        let escrow = makeAddress("0xe1c4d3dce17bc111181ddf716f75bae49e61a336")
        // An unknown (zero) channel id reads the mapping default: a zeroed channel.
        let channel = try await TempoEscrow.readChannel(
            Data(repeating: 0, count: 32), escrow: escrow, via: rpc
        )
        #expect(channel.deposit == .zero)
        #expect(channel.finalized == false)
    }
}

private let liveEnabled = ProcessInfo.processInfo.environment["MPP_MODERATO_E2E"] == "1"

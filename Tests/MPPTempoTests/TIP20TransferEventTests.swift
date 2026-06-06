import Foundation
import MPPCore
import MPPEVM
import Testing
@testable import MPPTempo

@Suite("TIP20TransferEvent")
struct TIP20TransferEventTests {
    private static let currency = "0x20C0000000000000000000000000000000000001"
    private static let from = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    private static let recipient = "0x1111111111111111111111111111111111111111"
    private static let memo = Data(repeating: 0xAB, count: 32)

    // A 32-byte indexed topic word for an address: 12 zero bytes of left padding + the 20 address
    // bytes (how the chain encodes an indexed `address` topic).
    private func addressTopic(_ hex: String) throws -> String {
        let address = try #require(EthereumAddress(hex: hex))
        return (Data(repeating: 0, count: 12) + address.bytes).hexPrefixed
    }

    private func validLog(amount: String = "1000000") throws -> EVMLog {
        try EVMLog(
            address: Self.currency,
            topics: [
                TIP20TransferEvent.transferWithMemoTopic.hexPrefixed,
                addressTopic(Self.from),
                addressTopic(Self.recipient),
                Self.memo.hexPrefixed,
            ],
            data: #require(EIP712.uint256(decimal: amount)).hexPrefixed
        )
    }

    @Test("the event topic matches the chain's keccak256(TransferWithMemo signature)")
    func eventTopic() {
        // Cross-checked against viem's
        // keccak256(toBytes("TransferWithMemo(address,address,uint256,bytes32)")).
        #expect(
            TIP20TransferEvent.transferWithMemoTopic.hexPrefixed
                == "0x57bc7354aa85aed339e000bccffabbc529466af35f0772c8f8ee1145927de7f0"
        )
    }

    @Test("decodes a TransferWithMemo log into currency, from, to, amount, memo")
    func decodesValidLog() throws {
        let decoded = try #require(TIP20TransferEvent.transferWithMemo(from: validLog()))
        #expect(decoded.currency == EthereumAddress(hex: Self.currency))
        #expect(decoded.from == EthereumAddress(hex: Self.from))
        #expect(decoded.recipient == EthereumAddress(hex: Self.recipient))
        #expect(try decoded.amount == Amount("1000000"))
        #expect(decoded.memo == Self.memo)
    }

    @Test("a large uint256 amount decodes to its exact base-10 value")
    func decodesLargeAmount() throws {
        // 2^200, well beyond UInt64, to exercise the arbitrary-precision word -> decimal path.
        let big = "1606938044258990275541962092341162602522202993782792835301376"
        let decoded = try #require(TIP20TransferEvent.transferWithMemo(from: validLog(amount: big)))
        #expect(try decoded.amount == Amount(big))
    }

    @Test("a log with a different event topic is not a TransferWithMemo")
    func rejectsWrongTopic() throws {
        var log = try validLog()
        log = EVMLog(
            address: log.address,
            topics: ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
                + log.topics.dropFirst(),
            data: log.data
        )
        #expect(TIP20TransferEvent.transferWithMemo(from: log) == nil)
    }

    @Test("a log without the four indexed topics is not a TransferWithMemo")
    func rejectsWrongTopicCount() throws {
        let log = try validLog()
        let threeTopics = EVMLog(
            address: log.address, topics: Array(log.topics.prefix(3)), data: log.data
        )
        #expect(TIP20TransferEvent.transferWithMemo(from: threeTopics) == nil)
    }

    @Test("a non-32-byte memo topic is rejected")
    func rejectsShortMemo() throws {
        let log = try validLog()
        let shortMemo = EVMLog(
            address: log.address,
            topics: Array(log.topics.prefix(3)) + [Data(repeating: 0xAB, count: 16).hexPrefixed],
            data: log.data
        )
        #expect(TIP20TransferEvent.transferWithMemo(from: shortMemo) == nil)
    }
}

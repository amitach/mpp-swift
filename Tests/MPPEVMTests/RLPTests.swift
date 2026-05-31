import Foundation
import Testing
@testable import MPPEVM

// Vectors from the Ethereum RLP specification
// (https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/). The decoder also
// parses attacker-supplied bytes (a server decoding a payment credential), so its rejection of
// hostile inputs (over-deep nesting, truncation, non-canonical lengths, trailing bytes) is tested.
@Suite("RLP encode/decode + adversarial inputs")
struct RLPTests {
    private func data(_ hex: String) throws -> Data {
        try #require(Data(hexPrefixed: hex))
    }

    @Test("canonical encodings from the RLP spec")
    func canonicalEncodings() throws {
        #expect(try RLP.encode(.bytes(Data("dog".utf8))) == data("0x83646f67"))
        #expect(try RLP.encode(.bytes(Data())) == data("0x80"))
        #expect(try RLP.encode(.list([])) == data("0xc0"))
        #expect(try RLP.encode(.list([.bytes(Data("cat".utf8)), .bytes(Data("dog".utf8))]))
            == data("0xc88363617483646f67"))
        // A single byte < 0x80 is itself; 0x80 needs a length prefix.
        #expect(RLP.encode(.bytes(Data([0x00]))) == Data([0x00]))
        #expect(RLP.encode(.bytes(Data([0x7F]))) == Data([0x7F]))
        #expect(try RLP.encode(.bytes(Data([0x80]))) == data("0x8180"))
    }

    @Test("a long string uses the multi-byte length form and round-trips")
    func longStringRoundTrip() throws {
        let payload = Data(repeating: 0xAB, count: 1024)
        let encoded = RLP.encode(.bytes(payload))
        #expect(encoded[encoded.startIndex] == 0xB9) // 0xb7 + 2 length bytes
        #expect(try RLP.decode(encoded) == .bytes(payload))
    }

    @Test("nested lists round-trip")
    func nestedRoundTrip() throws {
        let item = RLP.Item.list([
            .bytes(Data([0x01])),
            .list([.bytes(Data("abc".utf8)), .list([])]),
            .bytes(Data()),
        ])
        #expect(try RLP.decode(RLP.encode(item)) == item)
    }

    @Test("decoding rejects nesting deeper than maxDepth (stack-exhaustion guard)")
    func rejectsOverDeepNesting() throws {
        var item = RLP.Item.list([])
        for _ in 0 ... (RLP.maxDepth + 2) {
            item = .list([item])
        }
        let encoded = RLP.encode(item)
        #expect(throws: RLP.DecodingError.tooDeep) { try RLP.decode(encoded) }
    }

    @Test("decoding rejects truncated, non-canonical-length, and trailing-byte inputs")
    func rejectsMalformed() throws {
        // Declares a 4-byte string but supplies one byte.
        #expect(throws: RLP.DecodingError.truncated) { try RLP.decode(data("0x8401")) }
        // Long-length form with a leading-zero length byte (non-canonical).
        #expect(throws: RLP.DecodingError.nonCanonicalLength) {
            try RLP.decode(data("0xb90001ff"))
        }
        // An 8-byte length whose top bit is set overflows Int (rejected as non-canonical).
        #expect(throws: RLP.DecodingError.nonCanonicalLength) {
            try RLP.decode(data("0xbfffffffffffffffff"))
        }
        // A valid item followed by a stray trailing byte.
        #expect(throws: RLP.DecodingError.trailingBytes) { try RLP.decode(data("0x80ff")) }
    }
}

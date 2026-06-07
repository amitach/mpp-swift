import Foundation
import Testing
@testable import MPPEVM

@Suite("EIP712.uint256Decimal")
struct EIP712UInt256DecimalTests {
    @Test("decodes a big-endian word to its base-10 value")
    func goldens() throws {
        let zero = Data(repeating: 0, count: 32)
        #expect(EIP712.uint256Decimal(zero) == "0")

        // 1_000_000 = 0x0f4240 in the low bytes.
        let million = try #require(EIP712.uint256(decimal: "1000000"))
        #expect(EIP712.uint256Decimal(million) == "1000000")

        // 2^256 - 1 (the max), all 0xff.
        let max = Data(repeating: 0xFF, count: 32)
        #expect(
            EIP712.uint256Decimal(max)
                == "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        )
    }

    @Test("round-trips against uint256(decimal:) for representative values")
    func roundTrip() throws {
        for value in ["0", "1", "255", "256", "1000000", "999999999999999999999999999999"] {
            let word = try #require(EIP712.uint256(decimal: value))
            #expect(EIP712.uint256Decimal(word) == value)
        }
    }

    @Test("the result is canonical: no leading zeros")
    func canonicalNoLeadingZeros() throws {
        let word = try #require(EIP712.uint256(decimal: "42"))
        #expect(EIP712.uint256Decimal(word) == "42")
        #expect(!EIP712.uint256Decimal(word).hasPrefix("0"))
    }
}

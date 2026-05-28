import Foundation
import Testing
@testable import MPPCore

// Spec: draft-payment-intent-charge-00 (amount in base units) +
//       draft-payment-discovery-00 (amount grammar `0 / [1-9][0-9]*`).
// Reference comparison:
//   mppx  src/zod.ts:9          -> /^\d+(\.\d+)?$/  (lenient input: decimals + leading zeros)
//   mppx  src/discovery:12      -> /^(0|[1-9][0-9]*)$/  (strict, matches ours)
//   mpp-rs charge.rs:87         -> parse_amount() lenient u128 parse
// Verdict (G3.5): the on-wire amount is a canonical base-units integer; we use
// the discovery grammar (strict, no leading zeros). Decimal human input +
// decimals conversion is a charge-layer helper, not a valid Amount.
@Suite("Amount")
struct AmountTests {
    @Test("accepts canonical base-units integers, including zero")
    func acceptsCanonicalIntegers() throws {
        #expect(try Amount("0").rawValue == "0")
        #expect(try Amount("1").rawValue == "1")
        #expect(try Amount("1000000").rawValue == "1000000")
    }

    @Test("rejects an empty value")
    func rejectsEmpty() {
        #expect(throws: Amount.ValidationError.empty) {
            try Amount("")
        }
    }

    @Test("rejects decimals (base units are integers; decimals are input-only)")
    func rejectsDecimals() {
        #expect(throws: Amount.ValidationError.invalidCharacter(".")) {
            try Amount("1.5")
        }
    }

    @Test("rejects negatives and non-digits")
    func rejectsNonDigits() {
        #expect(throws: Amount.ValidationError.invalidCharacter("-")) {
            try Amount("-5")
        }
        #expect(throws: Amount.ValidationError.invalidCharacter("a")) {
            try Amount("1a")
        }
    }

    @Test("rejects leading zeros but accepts a lone zero")
    func rejectsLeadingZeros() throws {
        #expect(throws: Amount.ValidationError.leadingZero) {
            try Amount("007")
        }
        #expect(try Amount("0").rawValue == "0")
    }

    @Test("constructs from an unsigned integer canonically")
    func constructsFromUInt64() {
        #expect(Amount(0).rawValue == "0")
        #expect(Amount(1_000_000).rawValue == "1000000")
    }

    @Test("uint64Value parses, and is nil when the amount exceeds 64 bits")
    func uint64ValueOverflow() throws {
        #expect(try Amount("1000000").uint64Value == 1_000_000)
        // 10^26, far beyond UInt64.max (~1.8e19): a valid Amount, but no UInt64.
        let huge = try Amount("100000000000000000000000000")
        #expect(huge.uint64Value == nil)
    }

    @Test("encodes transparently and decoding validates")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Amount("1000000"))
        #expect(data == Data("\"1000000\"".utf8))

        let decoded = try JSONDecoder().decode(Amount.self, from: Data("\"1000000\"".utf8))
        #expect(decoded.rawValue == "1000000")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Amount.self, from: Data("\"1.5\"".utf8))
        }
    }
}

import Foundation
import Testing
@testable import MPPCore

// Spec: draft-payment-intent-charge-00 (amount in base units) +
//       draft-payment-discovery-00 (amount grammar `0 / [1-9][0-9]*`).
// The on-wire amount is a canonical base-units integer using the discovery
// grammar (strict, no leading zeros). Decimal human input +
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
}

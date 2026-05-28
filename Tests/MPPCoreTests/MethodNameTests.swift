import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1.1 + Appendix A
//   payment-method-id = 1*LOWERALPHA ; LOWERALPHA = %x61-7A (a-z)
// Reference comparison:
//   mppx  src/Challenge.ts:31  -> method: z.string()      (no validation)
//   mpp-rs src/protocol/core/types.rs:38 -> normalizes to lowercase (does not reject)
// Verdict (G3.5): no convincing justification for the ref deviations; spec wins.
// We validate strictly and reject non-conforming input.
@Suite("MethodName")
struct MethodNameTests {
    @Test("accepts a lowercase-ASCII identifier (spec 1*LOWERALPHA)")
    func acceptsLowercaseAscii() throws {
        #expect(try MethodName("tempo").rawValue == "tempo")
        #expect(try MethodName("stripe").rawValue == "stripe")
        #expect(try MethodName("a").rawValue == "a")
    }

    @Test("rejects an empty value")
    func rejectsEmpty() {
        #expect(throws: MethodName.ValidationError.empty) {
            try MethodName("")
        }
    }

    // Spec: uppercase violates the lowercase requirement and is rejected.
    // This is where we diverge deliberately from mpp-rs, which would lowercase.
    @Test("rejects uppercase rather than normalizing it")
    func rejectsUppercase() {
        #expect(throws: MethodName.ValidationError.self) {
            try MethodName("TEMPO")
        }
        #expect(throws: MethodName.ValidationError.self) {
            try MethodName("Tempo")
        }
    }

    @Test("rejects digits and hyphens (LOWERALPHA is a-z only)")
    func rejectsDigitsAndHyphens() {
        #expect(throws: MethodName.ValidationError.self) {
            try MethodName("base2")
        }
        #expect(throws: MethodName.ValidationError.self) {
            try MethodName("fee-payer")
        }
    }

    @Test("rejects non-ASCII lowercase letters")
    func rejectsNonAsciiLowercase() {
        #expect(throws: MethodName.ValidationError.self) {
            try MethodName("straße")
        }
        #expect(throws: MethodName.ValidationError.self) {
            try MethodName("café")
        }
    }

    @Test("reports the first invalid character")
    func reportsFirstInvalidCharacter() {
        #expect(throws: MethodName.ValidationError.invalidCharacter("2")) {
            try MethodName("ba2se")
        }
    }

    @Test("encodes transparently as a JSON string (mpp-rs serde-transparent parity)")
    func encodesTransparently() throws {
        let method = try MethodName("tempo")
        let data = try JSONEncoder().encode(method)
        #expect(data == Data("\"tempo\"".utf8))
    }

    @Test("decoding validates and round-trips")
    func decodingValidatesAndRoundTrips() throws {
        let decoded = try JSONDecoder().decode(MethodName.self, from: Data("\"tempo\"".utf8))
        #expect(try decoded == MethodName("tempo"))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MethodName.self, from: Data("\"TEMPO\"".utf8))
        }
    }
}

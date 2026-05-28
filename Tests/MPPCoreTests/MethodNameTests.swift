import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1.1 + Appendix A
//   payment-method-id = 1*LOWERALPHA ; LOWERALPHA = %x61-7A (a-z)
// We validate strictly and reject non-conforming input (uppercase, digits,
// hyphens, non-ASCII, empty) per the grammar, rather than normalizing it.
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

    @Test("encodes transparently as a JSON string")
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

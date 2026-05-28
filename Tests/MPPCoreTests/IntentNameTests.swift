import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1.1 + Appendix A
//   intent-token = 1*( ALPHA / DIGIT / "-" )   ; mixed case, digits, hyphens
// Reference comparison:
//   mppx  src/Challenge.ts:29  -> intent: z.string()    (no validation)
//   mpp-rs src/protocol/core/types.rs:107 -> lowercases the intent (deviation)
// Verdict (G3.5): the spec does not mandate lowercase for intent, so lowercasing
// is wrong; spec wins. We validate the grammar and preserve case exactly.
@Suite("IntentName")
struct IntentNameTests {
    @Test("accepts the registered intents and exposes them as constants")
    func acceptsRegisteredIntents() throws {
        #expect(IntentName.charge.rawValue == "charge")
        #expect(IntentName.session.rawValue == "session")
        #expect(IntentName.subscription.rawValue == "subscription")
        #expect(try IntentName("charge") == .charge)
    }

    @Test("accepts digits and hyphens (intent-token grammar)")
    func acceptsDigitsAndHyphens() throws {
        #expect(try IntentName("x402").rawValue == "x402")
        #expect(try IntentName("deep-research").rawValue == "deep-research")
    }

    // The spec does not require lowercase for intent: preserve case, do not
    // normalize. This is where we diverge deliberately from mpp-rs.
    @Test("preserves case rather than lowercasing")
    func preservesCase() throws {
        #expect(try IntentName("Charge").rawValue == "Charge")
        #expect(try IntentName("Charge") != .charge)
    }

    @Test("rejects an empty value")
    func rejectsEmpty() {
        #expect(throws: IntentName.ValidationError.empty) {
            try IntentName("")
        }
    }

    @Test("rejects spaces, control characters, and non-ASCII")
    func rejectsDisallowedCharacters() {
        #expect(throws: IntentName.ValidationError.self) {
            try IntentName("two words")
        }
        #expect(throws: IntentName.ValidationError.self) {
            try IntentName("charge\n")
        }
        #expect(throws: IntentName.ValidationError.self) {
            try IntentName("café")
        }
    }

    @Test("encodes transparently and decoding validates")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(IntentName.session)
        #expect(data == Data("\"session\"".utf8))

        let decoded = try JSONDecoder().decode(IntentName.self, from: Data("\"session\"".utf8))
        #expect(decoded == .session)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IntentName.self, from: Data("\"two words\"".utf8))
        }
    }
}

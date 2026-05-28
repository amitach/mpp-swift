import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1 — expires/timestamp are RFC 3339
// date-time strings. The original string is preserved verbatim; comparisons use
// the parsed instant.
@Suite("RFC3339DateTime")
struct RFC3339DateTimeTests {
    @Test("parses a Z timestamp and preserves the string")
    func parsesZuluVerbatim() throws {
        let value = try RFC3339DateTime("2026-01-02T03:04:05Z")
        #expect(value.rawValue == "2026-01-02T03:04:05Z")
        #expect(value.date == Date(timeIntervalSince1970: 1_767_323_045))
    }

    @Test("parses fractional seconds")
    func parsesFractionalSeconds() throws {
        let value = try RFC3339DateTime("2026-01-02T03:04:05.250Z")
        #expect(value.rawValue == "2026-01-02T03:04:05.250Z")
    }

    @Test("parses a numeric UTC offset")
    func parsesNumericOffset() throws {
        let offset = try RFC3339DateTime("2026-01-02T03:04:05+05:30")
        let zulu = try RFC3339DateTime("2026-01-01T21:34:05Z")
        #expect(offset.date == zulu.date)
        #expect(offset.rawValue == "2026-01-02T03:04:05+05:30")
    }

    @Test("equality is by the verbatim string, not the instant")
    func equalityIsByRawValue() throws {
        // Same instant, different encodings: distinct values (wire bytes differ),
        // because the string may be HMAC-bound. Use `.date` for instant equality.
        let zulu = try RFC3339DateTime("2026-01-02T03:04:05Z")
        let offset = try RFC3339DateTime("2026-01-02T03:04:05+00:00")
        #expect(zulu.date == offset.date)
        #expect(zulu != offset)
    }

    @Test("formats an instant as Z without fractional seconds")
    func formatsInstant() {
        let value = RFC3339DateTime(date: Date(timeIntervalSince1970: 1_767_323_045))
        #expect(value.rawValue == "2026-01-02T03:04:05Z")
    }

    @Test("init(date:) keeps date consistent with the whole-second rawValue")
    func initFromDateIsSelfConsistent() throws {
        // A sub-second instant: rawValue drops the fraction, and date must match
        // rawValue (not the input) so encode/decode is stable and equality holds.
        let value = RFC3339DateTime(date: Date(timeIntervalSince1970: 1_767_323_045.75))
        #expect(value.rawValue == "2026-01-02T03:04:05Z")
        #expect(try value == RFC3339DateTime(value.rawValue))
    }

    @Test(
        "rejects malformed timestamps",
        arguments: ["", "not-a-date", "2026-13-01T00:00:00Z", "2026-01-02 03:04:05"]
    )
    func rejectsMalformed(input: String) {
        #expect(throws: RFC3339DateTime.ParsingError.malformed) {
            try RFC3339DateTime(input)
        }
    }

    @Test("round-trips transparently through Codable as a single JSON string")
    func codableIsTransparent() throws {
        let value = try RFC3339DateTime("2026-01-02T03:04:05Z")
        let data = try JSONEncoder().encode(value)
        #expect(String(bytes: data, encoding: .utf8) == "\"2026-01-02T03:04:05Z\"")
        #expect(try JSONDecoder().decode(RFC3339DateTime.self, from: data) == value)
    }
}

import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1: Payment-Receipt is a base64url-encoded
// JSON object with status/method/timestamp/reference; status is "success"
// (receipts issued only on success).
@Suite("Receipt")
struct ReceiptTests {
    /// base64url of a compact JSON object built from ordered string fields.
    private func encoded(_ pairs: [(String, String)]) -> String {
        let body = pairs.map { #""\#($0.0)":"\#($0.1)""# }.joined(separator: ",")
        return Base64URL.encode(Data("{\(body)}".utf8))
    }

    private func sample() throws -> Receipt {
        try Receipt(
            method: MethodName("tempo"),
            timestamp: RFC3339DateTime("2026-01-02T03:04:05Z"),
            reference: "0xabc123"
        )
    }

    @Test("encodes to base64url JSON and decodes back")
    func roundTripsThroughHeader() throws {
        let receipt = try sample()
        let decoded = try Receipt(headerValue: receipt.headerValue)
        #expect(decoded == receipt)
    }

    @Test("header value is base64url of the sorted-key JSON")
    func headerValueIsCanonical() throws {
        let receipt = try sample()
        let expected = encoded([
            ("method", "tempo"), ("reference", "0xabc123"),
            ("status", "success"), ("timestamp", "2026-01-02T03:04:05Z"),
        ])
        #expect(try receipt.headerValue == expected)
    }

    @Test("decodes a server-shaped receipt")
    func decodesServerShape() throws {
        let receipt = try Receipt(headerValue: encoded([
            ("status", "success"), ("method", "stripe"),
            ("timestamp", "2026-05-01T12:00:00Z"), ("reference", "pi_123"),
        ]))
        #expect(receipt.status == .success)
        #expect(receipt.method.rawValue == "stripe")
        #expect(receipt.timestamp.rawValue == "2026-05-01T12:00:00Z")
        #expect(receipt.reference == "pi_123")
    }

    @Test("rejects an unrecognized status")
    func rejectsUnknownStatus() {
        let value = encoded([
            ("status", "pending"), ("method", "tempo"),
            ("timestamp", "2026-01-02T03:04:05Z"), ("reference", "x"),
        ])
        #expect(throws: Receipt.ParsingError.self) {
            try Receipt(headerValue: value)
        }
    }

    @Test("rejects a malformed timestamp in the JSON")
    func rejectsMalformedTimestamp() {
        let value = encoded([
            ("status", "success"), ("method", "tempo"),
            ("timestamp", "nope"), ("reference", "x"),
        ])
        #expect(throws: Receipt.ParsingError.self) {
            try Receipt(headerValue: value)
        }
    }

    @Test("rejects an uppercase method in the JSON")
    func rejectsInvalidMethod() {
        let value = encoded([
            ("status", "success"), ("method", "Tempo"),
            ("timestamp", "2026-01-02T03:04:05Z"), ("reference", "x"),
        ])
        #expect(throws: Receipt.ParsingError.self) {
            try Receipt(headerValue: value)
        }
    }

    @Test("rejects a non-base64url header value")
    func rejectsInvalidBase64URL() {
        #expect(throws: Receipt.ParsingError.self) {
            try Receipt(headerValue: "not base64url!!")
        }
    }

    @Test("captures unknown string fields into extras for forward/peer compatibility")
    func capturesUnknownStringFields() throws {
        let receipt = try Receipt(headerValue: encoded([
            ("status", "success"), ("method", "tempo"),
            ("timestamp", "2026-01-02T03:04:05Z"), ("reference", "r"),
            ("futureField", "kept"),
        ]))
        #expect(receipt.reference == "r")
        // Unknown string-valued fields are preserved in extras (not dropped), so a
        // session receipt's extra fields survive a decode/encode round-trip.
        #expect(receipt.extras["futureField"] == .string("kept"))
    }

    @Test("integer extras (units) encode as a JSON number and round-trip as .uint")
    func integerExtraIsNumericOnTheWire() throws {
        let receipt = try Receipt(
            method: MethodName("tempo"),
            timestamp: RFC3339DateTime("2026-01-02T03:04:05Z"),
            reference: "0xabc",
            extras: ["units": .uint(5), "channelId": .string("0xfeed")]
        )
        // The reference session receipt types every field as a string except `units`
        // (a JSON integer). So units must be an unquoted number on the wire, and a
        // string extra must stay quoted, else a strict peer rejects the receipt.
        let json = try #require(String(
            bytes: Base64URL.decode(receipt.headerValue),
            encoding: .utf8
        ))
        #expect(json.contains("\"units\":5"))
        #expect(!json.contains("\"units\":\"5\""))
        #expect(json.contains("\"channelId\":\"0xfeed\""))
        // Decode preserves the string/integer distinction.
        let decoded = try Receipt(headerValue: receipt.headerValue)
        #expect(decoded.extras["units"] == .uint(5))
        #expect(decoded.extras["channelId"] == .string("0xfeed"))
    }

    @Test("an integer extra above Int64.max round-trips (full u64 fidelity)")
    func largeUnsignedExtraRoundTrips() throws {
        // The reference `units` is a u64; a value past Int64.max must not narrow/drop.
        let big = UInt64(Int64.max) + 1
        let receipt = try Receipt(
            method: MethodName("tempo"),
            timestamp: RFC3339DateTime("2026-01-02T03:04:05Z"),
            reference: "0xabc",
            extras: ["units": .uint(big)]
        )
        let decoded = try Receipt(headerValue: receipt.headerValue)
        #expect(decoded.extras["units"] == .uint(big))
    }
}

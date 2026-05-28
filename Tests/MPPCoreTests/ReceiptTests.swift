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

    @Test("ignores unknown JSON fields for forward/peer compatibility")
    func ignoresUnknownFields() throws {
        let receipt = try Receipt(headerValue: encoded([
            ("status", "success"), ("method", "tempo"),
            ("timestamp", "2026-01-02T03:04:05Z"), ("reference", "r"),
            ("futureField", "ignored"),
        ]))
        #expect(receipt.reference == "r")
    }
}

import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1 + RFC 9110 auth-param grammar.
// Reference comparison (both agree):
//   mppx  src/Challenge.ts:355-465  -> scheme extraction + parseAuthParams,
//                                       rejects duplicate params (#98), quoted
//                                       escapes, multi-scheme (#160)
//   mpp-rs src/protocol/core/headers.rs:105-166 -> same, "Duplicate parameter"
// Verdict (G3.5): refs converge; implement spec-correct matching both. Values
// preserved verbatim (#418); duplicates rejected (#98); multi-scheme handled.
@Suite("PaymentAuthScheme")
struct PaymentAuthSchemeTests {
    @Test("parses comma-separated quoted parameters")
    func parsesQuotedParameters() throws {
        let params = try PaymentAuthScheme.parseParameters(
            from: #"Payment id="abc", method="tempo", intent="charge""#
        )
        #expect(params["id"] == "abc")
        #expect(params["method"] == "tempo")
        #expect(params["intent"] == "charge")
    }

    @Test("extracts the Payment scheme alongside another scheme (#160)")
    func extractsAmongMultipleSchemes() throws {
        let params = try PaymentAuthScheme.parseParameters(
            from: #"Bearer sometoken, Payment id="abc", method="tempo""#
        )
        #expect(params["id"] == "abc")
        #expect(params["method"] == "tempo")
    }

    @Test("preserves values verbatim, including colons in RFC 3339 timestamps (#418)")
    func preservesRawValues() throws {
        let params = try PaymentAuthScheme.parseParameters(
            from: #"Payment expires="2026-01-01T00:00:00Z""#
        )
        #expect(params["expires"] == "2026-01-01T00:00:00Z")
    }

    @Test("unescapes backslash escapes inside quoted values")
    func unescapesQuotedValues() throws {
        let params = try PaymentAuthScheme.parseParameters(
            from: #"Payment opaque="a\"b\\c""#
        )
        #expect(params["opaque"] == #"a"b\c"#)
    }

    @Test("accepts bare (unquoted) token values, trimmed")
    func acceptsBareValues() throws {
        let params = try PaymentAuthScheme.parseParameters(from: "Payment id=abc, method=tempo")
        #expect(params["id"] == "abc")
        #expect(params["method"] == "tempo")
    }

    @Test("rejects duplicate parameters (#98)")
    func rejectsDuplicateParameters() {
        #expect(throws: PaymentAuthScheme.ParseError.duplicateParameter("id")) {
            try PaymentAuthScheme.parseParameters(from: #"Payment id="a", method="tempo", id="b""#)
        }
    }

    @Test("rejects an unterminated quoted-string")
    func rejectsUnterminatedQuote() {
        #expect(throws: PaymentAuthScheme.ParseError.unterminatedQuotedString) {
            try PaymentAuthScheme.parseParameters(from: #"Payment id="abc"#)
        }
    }

    @Test("rejects a header with no Payment scheme")
    func rejectsMissingScheme() {
        #expect(throws: PaymentAuthScheme.ParseError.missingScheme) {
            try PaymentAuthScheme.parseParameters(from: "Bearer sometoken")
        }
    }

    @Test("does not match a longer scheme token like Payments")
    func doesNotMatchLongerSchemeToken() {
        #expect(throws: PaymentAuthScheme.ParseError.missingScheme) {
            try PaymentAuthScheme.parseParameters(from: #"Payments id="abc""#)
        }
    }

    @Test("formats ordered parameters, quoting and escaping values")
    func formatsParameters() {
        let header = PaymentAuthScheme.formatParameters([
            (key: "id", value: "abc"),
            (key: "method", value: "tempo"),
        ])
        #expect(header == #"Payment id="abc", method="tempo""#)
    }

    @Test("format escapes quotes and backslashes, round-tripping through parse")
    func formatRoundTripsSpecialCharacters() throws {
        let original = #"a"b\c"#
        let header = PaymentAuthScheme.formatParameters([(key: "opaque", value: original)])
        let parsed = try PaymentAuthScheme.parseParameters(from: header)
        #expect(parsed["opaque"] == original)
    }
}

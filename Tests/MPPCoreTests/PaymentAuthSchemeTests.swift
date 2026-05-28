import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1 + RFC 9110 auth-param grammar.
// Implemented per the spec: scheme extraction (multi-scheme aware), quoted-string
// escapes, duplicate-parameter rejection, and verbatim value preservation for
// challenge-id binding integrity.
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

    @Test("extracts the Payment scheme alongside another scheme")
    func extractsAmongMultipleSchemes() throws {
        let params = try PaymentAuthScheme.parseParameters(
            from: #"Bearer sometoken, Payment id="abc", method="tempo""#
        )
        #expect(params["id"] == "abc")
        #expect(params["method"] == "tempo")
    }

    @Test("preserves values verbatim, including colons in RFC 3339 timestamps")
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

    @Test("rejects duplicate parameters")
    func rejectsDuplicateParameters() {
        #expect(throws: PaymentAuthScheme.ParseError.duplicateParameter("id")) {
            try PaymentAuthScheme.parseParameters(from: #"Payment id="a", method="tempo", id="b""#)
        }
    }

    // RFC 9110 §11.2: auth-param names are case-insensitive. Names are
    // lower-cased on parse, so case variants collide (duplicate) and lookups
    // by the lowercase spec name always match.
    @Test("treats parameter names case-insensitively")
    func parameterNamesAreCaseInsensitive() throws {
        let params = try PaymentAuthScheme
            .parseParameters(from: #"Payment ID="abc", Method="tempo""#)
        #expect(params["id"] == "abc")
        #expect(params["method"] == "tempo")
    }

    @Test("rejects case-variant duplicate parameter names")
    func rejectsCaseVariantDuplicates() {
        #expect(throws: PaymentAuthScheme.ParseError.duplicateParameter("id")) {
            try PaymentAuthScheme.parseParameters(from: #"Payment id="a", ID="b""#)
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

import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1 — WWW-Authenticate: Payment carries
// required id/realm/method/intent/request and optional digest/expires/
// description/opaque. method is lowercase ASCII; request/opaque are
// base64url(JCS(json)) preserved verbatim for the challenge-id binding.
@Suite("Challenge")
struct ChallengeTests {
    private let request = EncodedJSON(json: ["amount": "1000000"]).rawValue
    private let opaque = EncodedJSON(json: ["ref": "abc"]).rawValue

    /// Renders a `Payment` header from ordered parameters, quoting each value.
    private func header(_ pairs: [(String, String)]) -> String {
        let rendered = pairs.map { #"\#($0.0)="\#($0.1)""# }.joined(separator: ", ")
        return "Payment \(rendered)"
    }

    private func required() -> [(String, String)] {
        [
            ("id", "abc"),
            ("realm", "api"),
            ("method", "tempo"),
            ("intent", "charge"),
            ("request", request),
        ]
    }

    @Test("parses the five required parameters")
    func parsesRequiredParameters() throws {
        let challenge = try Challenge(headerValue: header(required()))
        #expect(challenge.id == "abc")
        #expect(challenge.realm == "api")
        #expect(challenge.method.rawValue == "tempo")
        #expect(challenge.intent == .charge)
        #expect(challenge.request.rawValue == request)
        #expect(challenge.digest == nil)
        #expect(challenge.expires == nil)
        #expect(challenge.description == nil)
        #expect(challenge.opaque == nil)
    }

    @Test("parses all optional parameters")
    func parsesOptionalParameters() throws {
        let challenge = try Challenge(headerValue: header([
            ("id", "i"), ("realm", "r"), ("method", "stripe"),
            ("intent", "session"), ("request", request),
            ("digest", "sha-256=:xyz:"), ("expires", "2026-01-01T00:00:00Z"),
            ("description", "A resource"), ("opaque", opaque),
        ]))
        #expect(challenge.digest == "sha-256=:xyz:")
        #expect(challenge.expires?.rawValue == "2026-01-01T00:00:00Z")
        #expect(challenge.description == "A resource")
        #expect(challenge.opaque?.rawValue == opaque)
    }

    @Test("extracts Payment alongside another scheme")
    func parsesAmongMultipleSchemes() throws {
        let value = #"Bearer realm="other", \#(header(required()))"#
        let challenge = try Challenge(headerValue: value)
        #expect(challenge.method.rawValue == "tempo")
    }

    @Test("preserves request/opaque base64url verbatim, never re-encoding")
    func preservesEncodedValuesVerbatim() throws {
        // A request whose key order differs from canonical must survive untouched.
        let unsorted = "eyJiIjoyLCJhIjoxfQ"
        let value = header([
            ("id", "i"), ("realm", "r"), ("method", "tempo"),
            ("intent", "charge"), ("request", unsorted),
        ])
        let challenge = try Challenge(headerValue: value)
        #expect(challenge.request.rawValue == unsorted)
    }

    @Test(
        "rejects a missing required parameter",
        arguments: ["id", "realm", "method", "intent", "request"]
    )
    func rejectsMissingRequired(missing: String) {
        let value = header(required().filter { $0.0 != missing })
        #expect(throws: Challenge.ParsingError.missingParameter(missing)) {
            try Challenge(headerValue: value)
        }
    }

    @Test(
        "rejects a present-but-empty required parameter",
        // method/intent take this path too: the require guard fires before
        // MethodName/IntentName validation, so an empty value is reported as
        // .emptyParameter, not .invalidMethod/.invalidIntent.
        arguments: ["id", "realm", "method", "intent", "request"]
    )
    func rejectsEmptyRequired(empty: String) {
        let pairs = required().map { $0.0 == empty ? ($0.0, "") : $0 }
        #expect(throws: Challenge.ParsingError.emptyParameter(empty)) {
            try Challenge(headerValue: header(pairs))
        }
    }

    @Test("rejects an uppercase method (spec requires lowercase)")
    func rejectsInvalidMethod() {
        let value = header([
            ("id", "i"), ("realm", "r"), ("method", "Tempo"),
            ("intent", "charge"), ("request", request),
        ])
        #expect(throws: Challenge.ParsingError.self) {
            try Challenge(headerValue: value)
        }
    }

    @Test("rejects an intent outside the grammar")
    func rejectsInvalidIntent() {
        let value = header([
            ("id", "i"), ("realm", "r"), ("method", "tempo"),
            ("intent", "bad intent"), ("request", request),
        ])
        #expect(throws: Challenge.ParsingError.self) {
            try Challenge(headerValue: value)
        }
    }

    @Test("rejects a malformed expires")
    func rejectsInvalidExpires() {
        let value = header(required() + [("expires", "not-a-date")])
        #expect(throws: Challenge.ParsingError.self) {
            try Challenge(headerValue: value)
        }
    }

    @Test("rejects a header with no Payment scheme")
    func rejectsMissingScheme() {
        #expect(throws: Challenge.ParsingError.header(.missingScheme)) {
            try Challenge(headerValue: #"Bearer realm="x""#)
        }
    }

    @Test("encodes to a JSON object (for echoing in a credential), omitting absent optionals")
    func encodesAsJSONObject() throws {
        let challenge = try Challenge(
            id: "i", realm: "r", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("REQ")
        )
        let data = try JSONEncoder().encode(challenge)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains(#""id":"i""#))
        #expect(!json.contains("digest"))
        #expect(!json.contains("null"))
        #expect(try JSONDecoder().decode(Challenge.self, from: data) == challenge)
    }

    @Test("round-trips through headerValue for a full challenge")
    func roundTripsThroughHeader() throws {
        let full = try Challenge(
            id: "i", realm: "r", method: MethodName("tempo"), intent: .charge,
            request: EncodedJSON(request), digest: "sha-256=:z:",
            expires: Expires("2026-01-01T00:00:00Z"),
            description: "desc", opaque: EncodedJSON(opaque)
        )
        let reparsed = try Challenge(headerValue: full.headerValue)
        #expect(reparsed == full)
    }

    // Spec: draft-httpauth-payment-00 §5.1.2.1.1 — the HMAC binding input is the
    // seven slots realm|method|intent|request|expires|digest|opaque, with empty
    // strings for absent optionals; `id` (the HMAC output) is not an input.
    @Test("binding input joins all seven slots with full fields present")
    func bindingInputFull() throws {
        let challenge = try Challenge(
            id: "ignored", realm: "r", method: MethodName("tempo"), intent: .charge,
            request: EncodedJSON("REQ"), digest: "D",
            expires: Expires("2026-01-01T00:00:00Z"), opaque: EncodedJSON("OPQ")
        )
        #expect(challenge.bindingInput == "r|tempo|charge|REQ|2026-01-01T00:00:00Z|D|OPQ")
    }

    @Test("binding input uses empty slots for absent optionals, not dropped ones")
    func bindingInputMinimal() throws {
        let challenge = try Challenge(
            id: "i", realm: "api", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("REQ")
        )
        #expect(challenge.bindingInput == "api|tempo|charge|REQ|||")
    }

    @Test("an absent expires keeps digest in its own slot (positional, not shifted)")
    func bindingInputPositional() throws {
        let challenge = try Challenge(
            id: "i", realm: "r", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("REQ"), digest: "D"
        )
        #expect(challenge.bindingInput == "r|tempo|charge|REQ||D|")
    }

    @Test("binding input excludes id (the HMAC output is not an input)")
    func bindingInputExcludesID() throws {
        let base = try Challenge(
            id: "first", realm: "r", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("REQ")
        )
        let other = try Challenge(
            id: "second", realm: "r", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("REQ")
        )
        #expect(base.bindingInput == other.bindingInput)
    }

    @Test("binding slot order is expires-then-digest, the reverse of the header order")
    func bindingInputExpiresBeforeDigest() throws {
        // expires set, digest absent, opaque set: expires fills slot 5, the
        // empty digest slot 6 sits between it and opaque. A digest-first order
        // (matching headerValue) would put the empty slot before expires.
        let challenge = try Challenge(
            id: "i", realm: "r", method: MethodName("tempo"), intent: .charge,
            request: EncodedJSON("REQ"),
            expires: Expires("2025-01-06T12:00:00Z"), opaque: EncodedJSON("OPQ")
        )
        #expect(challenge.bindingInput == "r|tempo|charge|REQ|2025-01-06T12:00:00Z||OPQ")
    }

    @Test("description is display-only and excluded from the binding input")
    func bindingInputExcludesDescription() throws {
        let withDescription = try Challenge(
            id: "i", realm: "r", method: MethodName("tempo"), intent: .charge,
            request: EncodedJSON("REQ"), description: "Buy a widget"
        )
        let without = try Challenge(
            id: "i", realm: "r", method: MethodName("tempo"),
            intent: .charge, request: EncodedJSON("REQ")
        )
        #expect(withDescription.bindingInput == without.bindingInput)
        #expect(withDescription.bindingInput == "r|tempo|charge|REQ|||")
    }

    @Test("binding input carries request/opaque verbatim, including JCS-significant bytes")
    func bindingInputVerbatim() throws {
        // An unsorted-key encoding must appear in the slot exactly as received.
        let challenge = try Challenge(
            id: "i", realm: "r", method: MethodName("tempo"), intent: .charge,
            request: EncodedJSON("eyJiIjoyLCJhIjoxfQ"), opaque: EncodedJSON("T3Bx")
        )
        // expires and digest are both absent: two empty slots before opaque.
        #expect(challenge.bindingInput == "r|tempo|charge|eyJiIjoyLCJhIjoxfQ|||T3Bx")
    }
}

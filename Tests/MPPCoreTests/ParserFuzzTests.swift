import Foundation
import Testing
@testable import MPPCore

// Spec: draft-httpauth-payment-00 §5.1 (WWW-Authenticate: Payment challenge,
// Authorization: Payment credential, Payment-Receipt receipt). These three
// types parse untrusted header bytes off the wire, so this suite is their fuzz
// floor: a curated, deterministic adversarial corpus that must never *trap*
// (force-unwrap, index out of bounds, integer overflow, JSON recursion blowup,
// quadratic time) and a stress round-trip corpus that pins canonicality.
//
// `Challenge`/`Credential`/`Receipt` parse with typed `throws(ParsingError)`, so
// "only a domain error escapes" is a compile-time guarantee; the runtime fuzz
// target is therefore purely no-trap. Each accepted input additionally re-parses
// from its own serialization (idempotence), giving every case a real invariant.
//
// The corpus mirrors the reference SDK's fuzz categories (arbitrary input,
// unterminated quotes, escaped-char-at-boundary, comma floods, very long keys,
// NUL/control bytes) in the codebase's curated-deterministic idiom (see RLPTests),
// not random property testing: reproducible, reviewable, no extra dependency.

private let controlChars = String(String
    .UnicodeScalarView((0 ... 0x1F).map { Unicode.Scalar(UInt8($0)) }))

private func base64url(_ string: String) -> String {
    Base64URL.encode(Data(string.utf8))
}

// MARK: - Challenge

@Suite("Challenge parser fuzz")
struct ChallengeFuzzTests {
    static let adversarialHeaders: [String] = {
        var corpus: [String] = [
            // empty / scheme-only / whitespace / case variants
            "", " ", "\t", "\n", "Payment", "Payment ", "  Payment  ", "payment", "PAYMENT ",
            // arbitrary junk after the scheme
            "Payment !@#$%^&*()", "Payment 🔥💸", "Payment \t\n\r", "Payment =", "Payment ,",
            // unterminated quotes
            "Payment id=\"", "Payment id=\"abc", "Payment realm=\"x\", id=\"",
            // escaped character at the quote boundary
            "Payment id=\"\\", "Payment id=\"\\\"", "Payment id=\"\\\\", "Payment id=\"a\\",
            // structural noise floods
            "Payment " + String(repeating: "=", count: 500),
            "Payment " + String(repeating: ";", count: 500),
        ]
        // comma floods (n quadruples), per the reference fuzz category
        for reps in [1, 5, 50, 100] {
            corpus.append("Payment " + String(repeating: ",,,,", count: reps))
        }
        // very long keys (lowercased so they are grammar-valid param names)
        for len in [1000, 5000] {
            corpus.append("Payment " + String(repeating: "a", count: len) + "=\"val\"")
        }
        // very long value
        corpus.append("Payment id=\"" + String(repeating: "x", count: 5000) + "\"")
        // NUL + C0 control characters, inside a value and bare
        corpus.append("Payment id=\"" + controlChars + "\"")
        corpus.append("Payment id=" + controlChars)
        // unicode hazards: NUL scalar, RTL override, stacked combining marks
        corpus.append("Payment id=\"\u{0}\"")
        corpus.append("Payment id=\u{202E}abc")
        corpus.append("Payment realm=a\u{0301}\u{0301}\u{0301}b")
        // many quoted segments
        corpus.append("Payment " + String(repeating: "id=\"\\\"", count: 200))
        return corpus
    }()

    @Test("adversarial headers never trap; accepted ones round-trip", arguments: adversarialHeaders)
    func neverTraps(_ header: String) throws {
        // Reaching the end without trapping is the robustness guarantee. typed
        // throws already bounds the error to `ParsingError`, so we only need to
        // prove the parser is total and self-consistent on hostile input.
        guard let challenge = try? Challenge(headerValue: header) else { return }
        let reparsed = try Challenge(headerValue: challenge.headerValue)
        #expect(reparsed == challenge)
    }

    @Test("challenges(inHeaderValue:) is total on adversarial input", arguments: adversarialHeaders)
    func listIsTotal(_ header: String) throws {
        // The non-throwing list parser must never trap, and every challenge it
        // returns must itself re-parse to an equal value.
        for challenge in Challenge.challenges(inHeaderValue: header) {
            #expect(try Challenge(headerValue: challenge.headerValue) == challenge)
        }
    }

    /// Valid challenges whose field values stress the auth-param formatter:
    /// quotes, backslashes, commas, the binding `|`, unicode, and length. `method`
    /// and `intent` stay grammar-simple (the parser validates them); everything
    /// else may carry arbitrary bytes that must survive a serialize/parse round-trip.
    static func validCorpus() throws -> [Challenge] {
        let method = try MethodName("tempo")
        let intent = try IntentName("one-shot")
        let request = EncodedJSON("eyJhbW91bnQiOiIxMDAwIn0") // base64url(JCS), verbatim
        return try [
            Challenge(
                id: "id-1",
                realm: "api \"prod\"",
                method: method,
                intent: intent,
                request: request
            ),
            Challenge(
                id: "a,b,c",
                realm: "back\\slash",
                method: method,
                intent: intent,
                request: request
            ),
            Challenge(
                id: "pipe|in|id",
                realm: "r|e|a|l|m",
                method: method,
                intent: intent,
                request: request
            ),
            Challenge(
                id: "full", realm: "api", method: method, intent: intent, request: request,
                digest: "sha-256=:abc:", expires: Expires("2030-01-01T00:00:00Z"),
                description: "pay, please \"now\"", opaque: EncodedJSON("b3BhcXVl")
            ),
            Challenge(
                id: "snowman☃", realm: "naïve café", method: method, intent: intent,
                request: request, description: "🔥💸 émoji"
            ),
            Challenge(
                id: "long", realm: String(repeating: "r", count: 4000),
                method: method, intent: intent, request: request
            ),
        ]
    }

    @Test("valid challenges round-trip through the header under stress values")
    func roundTrip() throws {
        for challenge in try Self.validCorpus() {
            #expect(try Challenge(headerValue: challenge.headerValue) == challenge)
        }
    }

    @Test("several challenges on one header all round-trip (quoted commas do not mis-split)")
    func listRoundTrip() throws {
        let corpus = try Self.validCorpus()
        let header = corpus.map(\.headerValue).joined(separator: ", ")
        #expect(Challenge.challenges(inHeaderValue: header) == corpus)
    }
}

// MARK: - Credential

@Suite("Credential parser fuzz")
struct CredentialFuzzTests {
    static let adversarialHeaders: [String] = {
        var corpus: [String] = [
            // missing scheme / token
            "", " ", "Payment", "Payment ", "Payment   ", "Bearer abc", "payment ",
            // not base64url (standard-base64 chars, padding, whitespace, emoji)
            "Payment !!!!", "Payment ====", "Payment a+b/c=", "Payment with spaces", "Payment 🔥",
            // valid base64url that decodes to non-credential JSON
            "Payment " + base64url("not json at all"),
            "Payment " + base64url("[1,2,3]"),
            "Payment " + base64url("\"a string\""),
            "Payment " + base64url("12345"),
            "Payment " + base64url("null"),
            "Payment " + base64url("{}"),
            "Payment " + base64url("{\"challenge\":{}}"),
            "Payment " + base64url("{\"challenge\":{\"id\":\"x\"},\"payload\":{}}"),
        ]
        // deeply nested payload: Foundation's JSONDecoder caps nesting (~512) and
        // *throws* beyond it (verified empirically), so this reaches .invalidJSON
        // and never stack-overflows, so no depth guard is needed at our layer.
        let deep = "{\"challenge\":{\"id\":\"x\",\"realm\":\"r\",\"method\":\"tempo\","
            + "\"intent\":\"i\",\"request\":\"e30\"},\"payload\":{\"x\":"
            + String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000) + "}}"
        corpus.append("Payment " + base64url(deep))
        return corpus
    }()

    @Test("adversarial headers never trap; accepted ones round-trip", arguments: adversarialHeaders)
    func neverTraps(_ header: String) throws {
        guard let credential = try? Credential(headerValue: header) else { return }
        #expect(try Credential(headerValue: credential.headerValue) == credential)
    }

    @Test("valid credentials round-trip through the header")
    func roundTrip() throws {
        let challenge = try ChallengeFuzzTests.validCorpus()[3] // the all-optionals challenge
        let corpus: [Credential] = [
            Credential(challenge: challenge, payload: [:]),
            Credential(
                challenge: challenge,
                source: "did:example:123",
                payload: ["sig": .string("0xabc")]
            ),
            Credential(challenge: challenge, payload: [
                "nested": .object(["a": .array([.integer(1), .bool(true), .null, .string("x")])]),
                "unicode": .string("café ☃ 🔥"),
                "big": .integer(Int64.max),
            ]),
            Credential(
                challenge: challenge, source: "weird \"source\" |with| chars",
                payload: ["k": .string("v")]
            ),
        ]
        for credential in corpus {
            #expect(try Credential(headerValue: credential.headerValue) == credential)
        }
    }
}

// MARK: - Receipt

@Suite("Receipt parser fuzz")
struct ReceiptFuzzTests {
    static let adversarialHeaders: [String] = {
        var corpus: [String] = [
            "", " ", "!!!!", "====", "🔥", "not base64",
            base64url("[1,2,3]"), base64url("\"x\""), base64url("null"), base64url("{}"),
            // unknown status (only `success` is valid)
            base64url("{\"status\":\"failure\",\"method\":\"tempo\","
                + "\"timestamp\":\"2030-01-01T00:00:00Z\",\"reference\":\"r\"}"),
            // missing required fields
            base64url("{\"status\":\"success\",\"method\":\"tempo\"}"),
        ]
        // NUL + control bytes (invalid base64url alphabet) must reject, not trap
        corpus.append(controlChars)
        return corpus
    }()

    @Test("adversarial headers never trap; accepted ones round-trip", arguments: adversarialHeaders)
    func neverTraps(_ header: String) throws {
        guard let receipt = try? Receipt(headerValue: header) else { return }
        #expect(try Receipt(headerValue: receipt.headerValue) == receipt)
    }

    @Test("valid receipts round-trip through the header, including extras at the integer extreme")
    func roundTrip() throws {
        let method = try MethodName("tempo")
        let timestamp = try RFC3339DateTime("2030-01-01T00:00:00Z")
        let corpus: [Receipt] = [
            Receipt(method: method, timestamp: timestamp, reference: "0xabc"),
            Receipt(method: method, timestamp: timestamp, reference: "ref \"with\" |chars|"),
            Receipt(
                method: method, timestamp: timestamp, reference: "r",
                extras: [
                    "channelId": .string("0x1"),
                    "units": .uint(42),
                    "spent": .uint(UInt64.max),
                ]
            ),
            Receipt(method: method, timestamp: timestamp, reference: "café ☃"),
        ]
        for receipt in corpus {
            #expect(try Receipt(headerValue: receipt.headerValue) == receipt)
        }
    }
}

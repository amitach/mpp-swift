import Foundation
import Testing
@testable import MPPBodyDigest

// Spec: draft-httpauth-payment-00 §5.1 (the `digest` parameter) over RFC 9530
// Content-Digest, SHA-256, structured-field byte sequence (standard base64 with
// padding, colon-delimited).
@Suite("ContentDigest")
struct ContentDigestTests {
    @Test("computes the RFC 9530 golden vector for {\"hello\": \"world\"}")
    func computesGoldenVector() {
        // RFC 9530's own example body and digest.
        let body = Data(#"{"hello": "world"}"#.utf8)
        #expect(ContentDigest
            .compute(body) == "sha-256=:X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE=:")
    }

    @Test("computes the SHA-256 of the empty body")
    func computesEmptyBody() {
        #expect(ContentDigest
            .compute(Data()) == "sha-256=:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=:")
    }

    @Test("verifies a body against its own digest")
    func verifiesMatchingBody() throws {
        let body = Data("the request body".utf8)
        #expect(try ContentDigest.verify(body, matches: ContentDigest.compute(body)))
    }

    @Test("rejects a body whose digest does not match (tamper)")
    func rejectsTamperedBody() throws {
        let digest = ContentDigest.compute(Data("original".utf8))
        #expect(try !ContentDigest.verify(Data("tampered".utf8), matches: digest))
    }

    @Test("verifies against the sha-256 member when other algorithms are present")
    func verifiesAmongMultipleMembers() throws {
        let body = Data("body".utf8)
        let sha256 = ContentDigest.compute(body)
        let header = "sha-512=:\(Data(repeating: 0, count: 64).base64EncodedString()):, \(sha256)"
        #expect(try ContentDigest.verify(body, matches: header))
    }

    @Test("fails closed when the value carries no sha-256 member")
    func failsWhenNoSHA256() {
        let header = "sha-512=:\(Data(repeating: 0, count: 64).base64EncodedString()):"
        #expect(!ContentDigest.verify(Data("body".utf8), matches: header))
    }

    @Test("lower-cases the algorithm key on parse")
    func keyIsCaseInsensitive() throws {
        let body = Data("body".utf8)
        let upper = ContentDigest.compute(body).replacingOccurrences(of: "sha-256", with: "SHA-256")
        #expect(try ContentDigest.verify(body, matches: upper))
    }

    @Test("treats an empty byte sequence (sha-256=::) as a legal, non-matching member")
    func acceptsEmptyByteSequence() throws {
        // RFC 8941 permits an empty byte sequence; it parses (no throw) and just
        // cannot match a real body's digest.
        #expect(try !ContentDigest.verify(Data("body".utf8), matches: "sha-256=::"))
    }

    @Test(
        "a malformed Content-Digest value fails verification closed and is rejected by the parser",
        arguments: [
            "sha-256", // no '=' / no value
            "sha-256=abc", // value not a byte sequence (missing colons)
            "sha-256=:notbase64!:", // byte sequence is not valid base64
            "=:abc:", // empty key
        ]
    )
    func rejectsMalformed(header: String) {
        // verify fails closed (Bool); the parser reports the specific reason.
        #expect(!ContentDigest.verify(Data("body".utf8), matches: header))
        #expect(throws: ContentDigest.ParseError.self) {
            try ContentDigest.parse(header)
        }
    }

    @Test("the peer's bare, unframed digest form is rejected, not silently accepted (DIGEST-XSDK)")
    func rejectsBareUnframedDigest() throws {
        // Audit D2: the mppx peer emits a bare `sha-256=<base64>` (no RFC 9530 colon framing). We
        // keep the framed form; a bare value -- even one carrying the body's CORRECT digest -- must
        // fail closed, since our parser requires the framing. This is safe because the digest is
        // server-internal (only our verifier consumes it), so we never receive the peer's form.
        let body = Data("hello".utf8)
        let framed = ContentDigest.compute(body) // sha-256=:<b64>:
        // Strip the leading and trailing colons to get the peer's bare `sha-256=<base64>` form.
        let bare = framed.replacingOccurrences(of: "=:", with: "=")
        try #require(bare.hasPrefix("sha-256=") && !bare.contains(":")) // precondition: bare form
        #expect(!ContentDigest.verify(body, matches: bare)) // fail closed despite the right digest
        // The peer's form is also unpadded; strip the trailing base64 `=` to pin that exact shape.
        let bareUnpadded = bare.hasSuffix("=") ? String(bare.dropLast()) : bare
        #expect(!ContentDigest.verify(body, matches: bareUnpadded))
    }
}

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

    @Test("throws when the value carries no sha-256 member")
    func throwsWhenNoSHA256() {
        let header = "sha-512=:\(Data(repeating: 0, count: 64).base64EncodedString()):"
        #expect(throws: ContentDigest.ParseError.missingAlgorithm) {
            try ContentDigest.verify(Data("body".utf8), matches: header)
        }
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
        "rejects a malformed Content-Digest value",
        arguments: [
            "sha-256", // no '=' / no value
            "sha-256=abc", // value not a byte sequence (missing colons)
            "sha-256=:notbase64!:", // byte sequence is not valid base64
            "=:abc:", // empty key
        ]
    )
    func rejectsMalformed(header: String) {
        #expect(throws: ContentDigest.ParseError.self) {
            try ContentDigest.verify(Data("body".utf8), matches: header)
        }
    }
}

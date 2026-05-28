import Foundation
import Testing
@testable import MPPCore

// Spec: draft-payment-intent-charge-00 — request/credential are base64url,
// no padding (RFC 4648 §5). Reference comparison:
//   mppx  Base64.fromString(json, { pad: false, url: true })
//   mpp-rs base64url_encode/decode (URL_SAFE_NO_PAD)
// Verdict (G3.5): both unpadded base64url; we match, and decode strictly
// (reject standard-base64 chars and padding).
@Suite("Base64URL")
struct Base64URLTests {
    @Test("matches RFC 4648 test vectors, unpadded")
    func rfc4648Vectors() {
        #expect(Base64URL.encode(Data("".utf8)) == "")
        #expect(Base64URL.encode(Data("f".utf8)) == "Zg")
        #expect(Base64URL.encode(Data("fo".utf8)) == "Zm8")
        #expect(Base64URL.encode(Data("foo".utf8)) == "Zm9v")
        #expect(Base64URL.encode(Data("foob".utf8)) == "Zm9vYg")
        #expect(Base64URL.encode(Data("fooba".utf8)) == "Zm9vYmE")
        #expect(Base64URL.encode(Data("foobar".utf8)) == "Zm9vYmFy")
    }

    @Test("encode never emits padding")
    func noPadding() {
        for length in 0 ... 32 {
            let data = Data((0 ..< length).map { UInt8($0 & 0xFF) })
            #expect(!Base64URL.encode(data).contains("="))
        }
    }

    @Test("uses the URL-safe alphabet (- and _ instead of + and /)")
    func urlSafeAlphabet() {
        // Bytes 0xFB 0xFF encode to "+/8=" in standard base64.
        let encoded = Base64URL.encode(Data([0xFB, 0xFF]))
        #expect(encoded == "-_8")
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test("round-trips arbitrary bytes")
    func roundTrips() throws {
        for length in 0 ... 64 {
            let data = Data((0 ..< length).map { _ in UInt8.random(in: 0 ... 255) })
            let decoded = try Base64URL.decode(Base64URL.encode(data))
            #expect(decoded == data)
        }
    }

    @Test("rejects standard-base64 characters and padding")
    func rejectsStandardBase64() {
        #expect(throws: Base64URL.DecodeError.invalidCharacter) {
            try Base64URL.decode("-_8=") // padding not allowed
        }
        #expect(throws: Base64URL.DecodeError.invalidCharacter) {
            try Base64URL.decode("ab+/") // standard alphabet not allowed
        }
    }

    @Test("rejects an impossible length")
    func rejectsImpossibleLength() {
        #expect(throws: Base64URL.DecodeError.invalidLength) {
            try Base64URL.decode("A") // remainder 1 is impossible
        }
    }

    @Test("decodes a known token")
    func decodesKnownToken() throws {
        #expect(try Base64URL.decode("Zm9vYmFy") == Data("foobar".utf8))
    }
}

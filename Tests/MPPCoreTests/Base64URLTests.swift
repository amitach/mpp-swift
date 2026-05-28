import Foundation
import Testing
@testable import MPPCore

// Spec: draft-payment-intent-charge-00 — request/credential are base64url,
// no padding (RFC 4648 §5). Reference comparison:
//   mppx   delegates to ox's Base64 (`{ pad: false, url: true }`) — no dedicated
//          base64url test to port.
//   mpp-rs delegates to the `base64` crate (URL_SAFE_NO_PAD) — likewise.
// Since both refs delegate base64url to a library, there is no ref grammar test
// to port; RFC 4648 §5 is the authoritative vector source, tested directly here.
// Verdict (G3.5): both are unpadded base64url; we match, and decode strictly
// (reject standard-base64 chars and padding, as URL_SAFE_NO_PAD does).
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

    @Test("round-trips bytes across all lengths and byte values, deterministically")
    func roundTrips() throws {
        // Deterministic byte pattern (no system randomness — see the no-flaky
        // contract). The multiplier walks every residue mod 256, so over the
        // length range every byte value is exercised.
        for length in 0 ... 64 {
            let data = Data((0 ..< length).map { UInt8(($0 &* 131 &+ 17) & 0xFF) })
            let decoded = try Base64URL.decode(Base64URL.encode(data))
            #expect(decoded == data)
        }
        // Exhaustive single-byte coverage (all 256 values).
        for byte in UInt8.min ... UInt8.max {
            let data = Data([byte])
            #expect(try Base64URL.decode(Base64URL.encode(data)) == data)
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

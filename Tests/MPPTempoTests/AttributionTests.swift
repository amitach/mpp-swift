import Foundation
import MPPTempo
import Testing

// The MPP attribution memo, pinned byte-for-byte against vectors produced by the reference
// SDK's own Attribution.encode (mppx@0.6.28 src/tempo/Attribution.ts, via npm pack). A drift
// in the tag, layout, or any keccak fingerprint trips immediately.
@Suite("Attribution memo")
struct AttributionTests {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("the tag is keccak256(\"mpp\")[0..3]")
    func tag() {
        #expect(hex(Attribution.tag) == "ef1ed712")
    }

    @Test("server-only memo matches the reference vector")
    func serverOnlyVector() {
        let memo = Attribution.encode(serverId: "api.example.com", challengeId: "test-challenge-1")
        #expect(memo.count == 32)
        #expect(hex(memo) == "ef1ed712011ece072f76bd8b82350e00000000000000000000329caf68a3973d")
    }

    @Test("memo with a clientId matches the reference vector")
    func withClientVector() {
        let memo = Attribution.encode(
            serverId: "api.example.com", challengeId: "test-challenge-1", clientId: "my-app"
        )
        #expect(hex(memo) == "ef1ed712011ece072f76bd8b82350e3a180fb9d0177aa2f371329caf68a3973d")
    }

    @Test("tag + version occupy the first 5 bytes")
    func tagAndVersionPrefix() {
        let memo = Attribution.encode(serverId: "api.example.com", challengeId: "c")
        #expect(memo.prefix(4) == Attribution.tag)
        #expect(memo[4] == Attribution.version)
    }

    @Test("no clientId leaves the client fingerprint zero")
    func anonymousClient() {
        let memo = Attribution.encode(serverId: "api.example.com", challengeId: "c")
        #expect(memo[15 ..< 25] == Data(repeating: 0, count: 10))
    }

    @Test("the challengeId binds the nonce: deterministic, and different ids differ")
    func challengeBoundNonce() {
        let memoA = Attribution.encode(serverId: "api.example.com", challengeId: "challenge-a")
        let memoB = Attribution.encode(serverId: "api.example.com", challengeId: "challenge-b")
        let memoARepeat = Attribution.encode(
            serverId: "api.example.com",
            challengeId: "challenge-a"
        )
        #expect(memoA == memoARepeat)
        #expect(memoA != memoB)
        // Only the trailing nonce (bytes 25..31) differs; tag/version/server are identical.
        #expect(memoA.prefix(25) == memoB.prefix(25))
        #expect(memoA.suffix(7) != memoB.suffix(7))
    }

    @Test("matches() binds to realm + challenge but ignores the (unpinned) clientId")
    func matchesIgnoresClientId() {
        let memoA = Attribution.encode(
            serverId: "api.example.com", challengeId: "c1", clientId: "app-a"
        )
        let memoB = Attribution.encode(
            serverId: "api.example.com", challengeId: "c1", clientId: "app-b"
        )
        // Both clients match -- the verifier does not pin clientId.
        #expect(Attribution.matches(memo: memoA, serverId: "api.example.com", challengeId: "c1"))
        #expect(Attribution.matches(memo: memoB, serverId: "api.example.com", challengeId: "c1"))
        // A wrong challenge or realm does not match (anti hash-reuse across challenges).
        #expect(!Attribution.matches(memo: memoA, serverId: "api.example.com", challengeId: "c2"))
        #expect(!Attribution.matches(memo: memoA, serverId: "other.example.com", challengeId: "c1"))
        // A non-MPP or wrong-size memo is not a match.
        #expect(!Attribution.matches(
            memo: Data(repeating: 0, count: 32), serverId: "api.example.com", challengeId: "c1"
        ))
        #expect(!Attribution.matches(
            memo: Data(repeating: 0xAB, count: 16), serverId: "api.example.com", challengeId: "c1"
        ))
    }
}

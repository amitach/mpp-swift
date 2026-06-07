import MPPCore
import MPPServer
import Testing

// B9: the challenge-expiry switch derived from a compatibility profile.
@Suite("MPPCompatibility profile (server switch)")
struct MPPCompatibilityServerTests {
    @Test("mppx requires expires; specCorrect makes it optional")
    func expiryPolicy() {
        #expect(ChallengeExpiryPolicy(.mppx) == .required)
        #expect(ChallengeExpiryPolicy(.specCorrect) == .optional)
    }
}

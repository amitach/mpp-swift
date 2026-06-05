import MPPCore
import MPPServer
import Testing

// B9: the challenge-expiry switch derived from a compatibility profile. ChallengeExpiryPolicy is
// Sendable-only (not Equatable), so match by case.
@Suite("MPPCompatibility profile (server switch)")
struct MPPCompatibilityServerTests {
    private func isRequired(_ policy: ChallengeExpiryPolicy) -> Bool {
        if case .required = policy { true } else { false }
    }

    @Test("mppx requires expires; specCorrect makes it optional")
    func expiryPolicy() {
        #expect(isRequired(ChallengeExpiryPolicy(.mppx)))
        #expect(!isRequired(ChallengeExpiryPolicy(.specCorrect)))
    }
}

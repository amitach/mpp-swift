import MPPCore
import MPPEVM
import MPPTempo
import Testing

// B9: a compatibility profile derives each divergence switch. These two switches live in the
// Tempo/EVM layer (ProofVariant in MPPTempo, SignatureMalleabilityPolicy in MPPEVM); their
// profile initializers live in MPPTempo because MPPEVM does not link MPPCore.
@Suite("MPPCompatibility profile (Tempo / EVM switches)")
struct MPPCompatibilityTempoTests {
    @Test("the mppx profile selects the peer-form defaults")
    func mppxProfile() {
        #expect(ProofVariant(.mppx) == .v2Realm)
        #expect(SignatureMalleabilityPolicy(.mppx) == .accepted)
    }

    @Test("the specCorrect profile selects the spec-faithful forms")
    func specCorrectProfile() {
        #expect(ProofVariant(.specCorrect) == .specChallengeId)
        #expect(SignatureMalleabilityPolicy(.specCorrect) == .rejectHighS)
    }
}

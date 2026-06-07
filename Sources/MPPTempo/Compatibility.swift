import MPPCore
import MPPEVM

// The compatibility-profile initializers for the two Tempo/EVM divergence switches. They live here
// (not in MPPEVM) because MPPEVM does not depend on MPPCore, so the `MPPCompatibility` profile is
// not visible there; MPPTempo links both, and any Tempo deployment links MPPTempo.

public extension ProofVariant {
    /// The zero-amount proof shape a compatibility profile selects: `.mppx` maps to ``v2Realm``
    /// (the
    /// realm-bound form live peers emit, this type's default); `.specCorrect` maps to
    /// ``specChallengeId`` (the normative single-field form).
    init(_ compatibility: MPPCompatibility) {
        self = switch compatibility {
        case .mppx: .v2Realm
        case .specCorrect: .specChallengeId
        }
    }
}

public extension SignatureMalleabilityPolicy {
    /// The malleability policy a compatibility profile selects: `.mppx` maps to ``accepted`` (the
    /// peer accepts a high-`s` signature, this type's default); `.specCorrect` maps to
    /// ``rejectHighS`` (EIP-2 canonical low-`s`).
    init(_ compatibility: MPPCompatibility) {
        self = switch compatibility {
        case .mppx: .accepted
        case .specCorrect: .rejectHighS
        }
    }
}

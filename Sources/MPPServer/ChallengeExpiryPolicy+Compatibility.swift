import MPPCore

public extension ChallengeExpiryPolicy {
    /// The expiry policy a compatibility profile selects: `.mppx` requires `expires` at
    /// verification
    /// (the peer behavior, and this type's default); `.specCorrect` makes it optional (the spec's
    /// optional-`expires` semantics).
    init(_ compatibility: MPPCompatibility) {
        self = switch compatibility {
        case .mppx: .required
        case .specCorrect: .optional
        }
    }
}

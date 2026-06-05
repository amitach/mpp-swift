/// A compatibility profile that selects, in one place, how the SDK resolves each behavior where the
/// `mppx` reference peer diverges from the published specification.
///
/// The SDK exposes a small set of independent divergence switches, each defaulting to the peer form
/// for live interop (per the AGENTS.md "switch, not silent inheritance" rule): the MCP error-code
/// mode (`MCPErrorCodeMode`), the challenge-expiry policy (`ChallengeExpiryPolicy`), the Tempo
/// zero-amount proof shape (`ProofVariant`), and the signature malleability policy
/// (`SignatureMalleabilityPolicy`). Each of those types provides an `init(_:)` that maps a profile
/// to its corresponding value, so a deployment can choose one profile and derive every switch from
/// it consistently rather than setting four knobs by hand:
///
/// ```swift
/// let profile = MPPCompatibility.mppx
/// let verifier = PaymentVerifier(..., expiryPolicy: .init(profile))
/// let proofVerifier = TempoProofVerifier(
///     acceptedVariants: [.init(profile)], malleability: .init(profile)
/// )
/// let mcpServer = MCPPaymentServer(..., codeMode: .init(profile))
/// ```
///
/// Because the switches live in different modules (and not every deployment links all of them),
/// this is a lightweight selector in `MPPCore` rather than an aggregate that imports every rail.
/// A deployment that wants a single value mixed differently still sets that one switch directly.
public enum MPPCompatibility: Sendable, Hashable {
    /// Match the `mppx` TypeScript reference SDK: the form live peers emit and accept today. This
    /// is
    /// what every divergence switch already defaults to, so `.mppx` reproduces the out-of-the-box
    /// behavior.
    case mppx
    /// Follow the published specification drafts where they diverge from the peer (stricter / more
    /// spec-faithful): spec MCP error codes, optional challenge `expires`, the normative
    /// single-field
    /// proof, and EIP-2 canonical low-`s` signatures. Target this only against a peer implemented
    /// to
    /// the spec rather than to the reference SDK.
    case specCorrect
}

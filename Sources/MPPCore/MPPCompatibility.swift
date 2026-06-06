/// A compatibility profile that selects, in one place, how the SDK resolves each behavior where the
/// `mppx` reference peer diverges from the published specification.
///
/// The SDK exposes a small set of independent divergence switches, each behind a compatibility
/// switch per the AGENTS.md "switch, not silent inheritance" rule: the MCP error-code mode
/// (`MCPErrorCodeMode`), the challenge-expiry policy (`ChallengeExpiryPolicy`), the Tempo
/// zero-amount proof shape (`ProofVariant`), and the signature malleability policy
/// (`SignatureMalleabilityPolicy`). AGENTS.md prescribes *defaulting* to the spec-correct form;
/// these switches instead default to the peer (`mppx`) form, a deliberate deviation ratified in the
/// parity/security audit because the spec-correct default breaks live interop with the reference
/// SDK (for example its client recognizes only the `-32042` MCP error code, not the spec `-32043`).
/// Each type provides an `init(_:)` that maps a profile to its corresponding value, so a deployment
/// can choose one profile and derive every switch from it consistently rather than setting four
/// knobs by hand:
///
/// ```swift
/// let profile = MPPCompatibility.mppx
/// // Server switches:
/// let verifier = PaymentVerifier(..., expiryPolicy: .init(profile))
/// let proofVerifier = TempoProofVerifier(malleability: .init(profile))
/// let mcpServer = MCPPaymentServer(..., codeMode: .init(profile))
/// // Client: the single proof shape to emit.
/// let proofMethod = TempoProofMethod(..., variant: .init(profile))
/// ```
///
/// Note on `ProofVariant`: `.init(profile)` is the single proof shape a *client* emits (and the
/// *primary* shape a peer expects). A server verifier accepts a *set* and deliberately defaults to
/// all three shapes for leniency; pass `acceptedVariants: [.init(profile)]` only when you actually
/// want to restrict it to exactly that shape (a stricter-than-default choice), not as the routine
/// way to apply a profile.
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

import CryptoSwift
import Foundation

/// Keccak-256, the Ethereum hash (**not** NIST SHA3-256; the padding differs:
/// Keccak appends `0x01`, SHA-3 appends `0x06`).
///
/// A thin wrapper over CryptoSwift's vetted `SHA3(variant: .keccak256)`. AGENTS.md
/// forbids hand-rolled cryptography, and swift-crypto ships only NIST SHA-3 (the
/// wrong function here), so the implementation is delegated to a pinned, audited
/// dependency rather than written by hand. The wrapper exists so callers (the
/// EIP-712 layer) depend on this stable `Keccak256.hash` surface, not on the
/// dependency directly: the provider can be swapped with no call-site changes.
///
/// Correctness is pinned by known-answer vectors (`Keccak256Tests`) spanning the
/// rate boundary and multi-block inputs, which also guard against a provider swap
/// silently selecting the wrong variant.
public enum Keccak256 {
    /// The 32-byte Keccak-256 digest of `input`.
    public static func hash(_ input: Data) -> Data {
        Data(SHA3(variant: .keccak256).calculate(for: [UInt8](input)))
    }
}

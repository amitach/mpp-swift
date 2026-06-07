import Foundation

/// Whether signature verification rejects a high-`s` (non-canonical) ECDSA signature.
///
/// An ECDSA signature `(r, s)` has a malleated twin `(r, n - s)` (with the recovery bit flipped)
/// that is equally valid and **recovers the same address**. EIP-2 / BIP-62 pin the canonical form
/// to the low half, `s <= n/2`. libsecp256k1 always emits low-`s`, so a signature this SDK produces
/// is canonical; a high-`s` value can only arrive from an external producer that did not normalize.
///
/// DIVERGING_FROM_SPEC (audit SIG-1): EIP-2 requires low-`s`, but the mppx peer does **not** reject
/// a high-`s` signature on verify, so this SDK defaults to the peer's behavior (``accepted``) for
/// interop. It is not exploitable: identity is the recovered address (the twin recovers the *same*
/// address, so accepting it grants nothing a forger could not already do by re-presenting the
/// original), and anti-replay is by monotonic/single-use accounting, not signature bytes. Select
/// ``rejectHighS`` to enforce strict EIP-2 canonical-`s`, ideally in coordination with the peer.
public enum SignatureMalleabilityPolicy: Sendable, Hashable {
    /// Accept a signature regardless of its `s` value: the default, matching the mppx peer.
    case accepted
    /// Reject a signature whose `s` is in the upper half of the curve order (`s > n/2`), enforcing
    /// the EIP-2 / BIP-62 canonical low-`s` form.
    case rejectHighS

    /// Whether `signature` satisfies this policy. ``accepted`` admits any signature;
    /// ``rejectHighS``
    /// admits only a low-`s` one.
    public func allows(_ signature: RecoverableSignature) -> Bool {
        switch self {
        case .accepted: true
        case .rejectHighS: signature.isLowS
        }
    }
}

public extension RecoverableSignature {
    /// Whether `s` is in the lower half of the curve order (`s <= n/2`): the EIP-2 / BIP-62
    /// canonical form. A high-`s` signature is the malleated twin of a canonical one and recovers
    /// the same address; see ``SignatureMalleabilityPolicy``.
    var isLowS: Bool {
        // `s` is the second 32 bytes of the compact `r || s` (big-endian). For equal-length
        // big-endian byte strings, lexicographic order is numeric order, so `s <= n/2` is
        // "n/2 does not lexicographically precede s".
        let sScalar = Array(compact.suffix(32))
        return !Self.halfCurveOrder.lexicographicallyPrecedes(sScalar)
    }

    /// The secp256k1 group order halved (`n / 2`), big-endian: the inclusive upper bound of a
    /// canonical low-`s` value.
    private static let halfCurveOrder: [UInt8] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
        0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
    ]
}

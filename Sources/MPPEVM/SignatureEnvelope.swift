import Foundation

/// Normalizes a Tempo **signature envelope** down to the bare 65-byte secp256k1 signature a
/// voucher (and the escrow's `ecrecover`) requires, at the transport/deserialize boundary.
///
/// Tempo serializes signatures in an envelope: a bare 65-byte `r ‖ s ‖ v` is plain secp256k1
/// (no type prefix), while typed envelopes lead with a type byte (`0x01` p256, `0x02` webAuthn,
/// `0x03`/`0x04` keychain), and any of them may carry a trailing 32-byte **magic trailer** (32
/// bytes of `0x77`) appended by local-account RPC routing. A channel voucher, by contrast, is
/// redeemed by the escrow contract via `ecrecover`, which accepts **only** a raw secp256k1
/// signature; keychain-, p256-, and webAuthn-wrapped signatures are not redeemable there.
///
/// So ``SignatureEnvelope`` keeps the crypto primitive
/// (``Voucher/verify(escrowContract:chainId:signature:expectedSigner:)``)
/// strict, canonical-65-byte-only, and absorbs envelope variation here instead: it strips the
/// magic trailer if present and accepts the result only when it is a bare 65-byte secp256k1
/// signature, rejecting every typed envelope. Stripping can only *remove* a transport artifact
/// from an otherwise-canonical signature; it can never turn an invalid signature into one that
/// recovers to a different signer (the recovered address still has to match), so the leniency is
/// safe.
public enum SignatureEnvelope {
    /// The 32-byte magic trailer (`0x77` repeated) a Tempo signature envelope may carry.
    static let magicTrailer = Data(repeating: 0x77, count: 32)

    /// The byte length of a canonical secp256k1 signature (`r ‖ s ‖ v`).
    private static let secp256k1Length = 65

    /// Returns the bare 65-byte secp256k1 signature for a voucher, normalizing an inbound Tempo
    /// signature envelope, or `nil` if the input is not redeemable as a raw `ecrecover` signature.
    ///
    /// - Strips a trailing 32-byte magic trailer when one is present (the input must be longer
    ///   than the trailer, so a value that is *only* the trailer is not mistaken for an empty
    ///   signature).
    /// - Accepts the remainder only when it is exactly 65 bytes (bare secp256k1); a typed envelope
    ///   (keychain `0x03`/`0x04`, p256 `0x01`, webAuthn `0x02`) is not 65 bytes and is rejected.
    public static func canonicalVoucherSignature(_ raw: Data) -> Data? {
        var bytes = raw
        if bytes.count > magicTrailer.count, bytes.suffix(magicTrailer.count) == magicTrailer {
            bytes = bytes.prefix(bytes.count - magicTrailer.count)
        }
        guard bytes.count == secp256k1Length else { return nil }
        return Data(bytes)
    }
}

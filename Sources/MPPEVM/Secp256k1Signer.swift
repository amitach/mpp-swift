import Foundation
import libsecp256k1

/// A secp256k1 ECDSA signer over a raw 32-byte message hash, producing a
/// recoverable signature (64-byte compact `r || s` plus a recovery id).
///
/// This is the EVM message-signing primitive for MPP proofs, session vouchers,
/// and subscription key-authorizations. The caller supplies the **already-hashed**
/// 32-byte value (e.g. an EIP-712 `hashStruct` digest); this signs it directly,
/// never re-hashing. Signing uses libsecp256k1's RFC 6979 deterministic nonce, so
/// a given (key, hash) always yields the same signature, and libsecp256k1 emits
/// low-`s` signatures by construction.
///
/// Built directly on Bitcoin Core's `libsecp256k1` (via `swift-secp256k1`) rather
/// than a higher-level wrapper, so the exact "sign this 32-byte hash" semantics are
/// explicit. The signing context is randomized once per signer for side-channel
/// hardening (randomization does not change the deterministic signature output).
///
/// - Note: the private key is held in a copyable `[UInt8]` for the signer's
///   lifetime and is **not** zeroized on release (Swift cannot reliably scrub a
///   copyable value). Scope a signer to the signing it performs, and source the
///   key from a secure store. Hardened key custody is a separate concern.
public struct Secp256k1Signer: Sendable {
    private let privateKey: [UInt8]
    private let context: Secp256k1Context
    private let publicKeyBytes: Data

    /// Creates a signer from a 32-byte secp256k1 private key.
    ///
    /// - Throws: ``KeyError/invalidLength`` if `privateKey` is not 32 bytes, or
    ///   ``KeyError/invalidKey`` if it is not a valid secp256k1 scalar.
    public init(privateKey: Data) throws(KeyError) {
        guard privateKey.count == 32 else { throw .invalidLength }
        let key = [UInt8](privateKey)
        let context = Secp256k1Context()
        guard secp256k1_ec_seckey_verify(context.raw, key) == 1 else { throw .invalidKey }
        self.privateKey = key
        self.context = context
        // Derive the public key once; the key is valid, so this cannot fail.
        var pubkey = secp256k1_pubkey()
        _ = secp256k1_ec_pubkey_create(context.raw, &pubkey, key)
        publicKeyBytes = Self.serialize(pubkey: &pubkey, context: context.raw)
    }

    /// The signer's public key, serialized uncompressed (65 bytes, `0x04` prefix).
    public var publicKey: Data {
        publicKeyBytes
    }

    /// Signs a 32-byte message hash, returning a recoverable signature.
    ///
    /// - Parameter hash: Exactly 32 bytes; signed directly with no further hashing.
    /// - Throws: ``SigningError/invalidHashLength`` if `hash` is not 32 bytes;
    ///   ``SigningError/signingFailed`` if libsecp256k1 rejects the operation
    ///   (not expected for a key validated at `init`).
    public func sign(hash: Data) throws(SigningError) -> RecoverableSignature {
        guard hash.count == 32 else { throw .invalidHashLength }
        let message = [UInt8](hash)
        var signature = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_sign_recoverable(
            context.raw, &signature, message, privateKey, nil, nil
        ) == 1 else {
            throw .signingFailed
        }
        var compact = [UInt8](repeating: 0, count: 64)
        var recoveryID: Int32 = 0
        _ = secp256k1_ecdsa_recoverable_signature_serialize_compact(
            context.raw, &compact, &recoveryID, &signature
        )
        // libsecp256k1 guarantees a 64-byte compact and recid in 0...3.
        return RecoverableSignature(unchecked: Data(compact), recoveryID: UInt8(recoveryID))
    }

    /// Recovers the signing public key (uncompressed, 65 bytes) from a recoverable
    /// signature over `hash`, or `nil` if recovery fails. Recovery is not
    /// verification: a recovered key is the candidate signer, to be compared
    /// against an expected address.
    ///
    /// Uses the shared static context (recovery touches no secret). All inputs are
    /// re-validated here, defensively, even though ``RecoverableSignature`` already
    /// enforces its 64-byte / `0...3` invariant: libsecp256k1 would otherwise read
    /// out of bounds or `abort()` the process on a malformed value, and this is the
    /// attacker-facing verification path.
    public static func recoverPublicKey(
        hash: Data, signature: RecoverableSignature
    ) -> Data? {
        guard hash.count == 32, signature.compact.count == 64, signature.recoveryID <= 3 else {
            return nil
        }
        // The static context is a non-null global; the guard satisfies the imported
        // optional without a force-unwrap.
        guard let context = secp256k1_context_static else { return nil }
        var parsed = secp256k1_ecdsa_recoverable_signature()
        let compact = [UInt8](signature.compact)
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(
            context, &parsed, compact, Int32(signature.recoveryID)
        ) == 1 else { return nil }
        var pubkey = secp256k1_pubkey()
        guard secp256k1_ecdsa_recover(context, &pubkey, &parsed, [UInt8](hash)) == 1 else {
            return nil
        }
        return serialize(pubkey: &pubkey, context: context)
    }

    private static func serialize(
        pubkey: inout secp256k1_pubkey, context: OpaquePointer
    ) -> Data {
        var output = [UInt8](repeating: 0, count: 65)
        var length = 65
        _ = secp256k1_ec_pubkey_serialize(
            context, &output, &length, &pubkey, UInt32(SECP256K1_EC_UNCOMPRESSED)
        )
        return Data(output.prefix(length))
    }

    /// A reason a private key was rejected.
    public enum KeyError: Error, Sendable, Hashable {
        /// The key was not exactly 32 bytes.
        case invalidLength
        /// The key was not a valid secp256k1 scalar (zero or >= the curve order).
        case invalidKey
    }

    /// A reason signing failed.
    public enum SigningError: Error, Sendable, Hashable {
        /// The message hash was not exactly 32 bytes.
        case invalidHashLength
        /// libsecp256k1 rejected the signing operation (not expected for a key
        /// validated at construction).
        case signingFailed
    }
}

/// A recoverable secp256k1 ECDSA signature: the 64-byte compact `r || s` and the
/// recovery id (`0...3`) needed to recover the signer's public key.
///
/// The 64-byte / `0...3` invariant is enforced at construction so it cannot be
/// violated downstream (libsecp256k1 reads a fixed 64-byte buffer and aborts on an
/// out-of-range recovery id).
public struct RecoverableSignature: Sendable, Hashable {
    /// The 64-byte compact signature, `r || s` big-endian, low-`s`.
    public let compact: Data
    /// The recovery id (`0...3`).
    public let recoveryID: UInt8

    /// Creates a recoverable signature, or `nil` if `compact` is not 64 bytes or
    /// `recoveryID` is not in `0...3`.
    public init?(compact: Data, recoveryID: UInt8) {
        guard compact.count == 64, recoveryID <= 3 else { return nil }
        self.init(unchecked: compact, recoveryID: recoveryID)
    }

    /// Unvalidated initializer for trusted producers (e.g. ``Secp256k1Signer/sign(hash:)``,
    /// whose libsecp256k1 output already satisfies the invariant).
    init(unchecked compact: Data, recoveryID: UInt8) {
        self.compact = compact
        self.recoveryID = recoveryID
    }

    /// The 65-byte `r || s || recoveryID` form (raw recovery id, not Ethereum's
    /// `27`-offset `v`; the offset is applied by the layer that knows the wire
    /// convention).
    public var serialized: Data {
        compact + Data([recoveryID])
    }
}

/// A randomized libsecp256k1 context, owned for a signer's lifetime and used for
/// the secret-key operations (signing, public-key derivation).
///
/// libsecp256k1 contexts are immutable after randomization and safe to use
/// concurrently, so this is `Sendable`; the C pointer is freed in `deinit`.
/// (Recovery and other public operations use the shared static context instead.)
final class Secp256k1Context: @unchecked Sendable {
    let raw: OpaquePointer

    init() {
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            preconditionFailure("secp256k1_context_create failed (out of memory)")
        }
        // Randomize for side-channel hardening; does not affect signature output.
        let seed = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        guard secp256k1_context_randomize(context, seed) == 1 else {
            preconditionFailure("secp256k1_context_randomize failed")
        }
        raw = context
    }

    deinit { secp256k1_context_destroy(raw) }
}

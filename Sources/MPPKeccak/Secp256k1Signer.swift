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
public struct Secp256k1Signer: Sendable {
    private let privateKey: [UInt8]
    private let context: Secp256k1Context

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
    }

    /// The signer's public key, serialized uncompressed (65 bytes, `0x04` prefix).
    public var publicKey: Data {
        var pubkey = secp256k1_pubkey()
        // Cannot fail: the key was validated in `init`.
        _ = secp256k1_ec_pubkey_create(context.raw, &pubkey, privateKey)
        return Self.serialize(pubkey: &pubkey, context: context.raw)
    }

    /// Signs a 32-byte message hash, returning a recoverable signature.
    ///
    /// - Parameter hash: Exactly 32 bytes; signed directly with no further hashing.
    /// - Throws: ``SigningError/invalidHashLength`` if `hash` is not 32 bytes.
    public func sign(hash: Data) throws(SigningError) -> RecoverableSignature {
        guard hash.count == 32 else { throw .invalidHashLength }
        let message = [UInt8](hash)
        var signature = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_sign_recoverable(
            context.raw, &signature, message, privateKey, nil, nil
        ) == 1 else {
            // Only fails for an invalid key, which `init` already ruled out.
            throw .invalidHashLength
        }
        var compact = [UInt8](repeating: 0, count: 64)
        var recoveryID: Int32 = 0
        _ = secp256k1_ecdsa_recoverable_signature_serialize_compact(
            context.raw, &compact, &recoveryID, &signature
        )
        return RecoverableSignature(compact: Data(compact), recoveryID: UInt8(recoveryID))
    }

    /// Recovers the signing public key (uncompressed, 65 bytes) from a recoverable
    /// signature over `hash`, or `nil` if recovery fails. Recovery is not
    /// verification: a recovered key is the candidate signer, to be compared
    /// against an expected address.
    public static func recoverPublicKey(
        hash: Data, signature: RecoverableSignature
    ) -> Data? {
        guard hash.count == 32 else { return nil }
        let context = Secp256k1Context()
        var parsed = secp256k1_ecdsa_recoverable_signature()
        let compact = [UInt8](signature.compact)
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(
            context.raw, &parsed, compact, Int32(signature.recoveryID)
        ) == 1 else { return nil }
        var pubkey = secp256k1_pubkey()
        guard secp256k1_ecdsa_recover(context.raw, &pubkey, &parsed, [UInt8](hash)) == 1 else {
            return nil
        }
        return serialize(pubkey: &pubkey, context: context.raw)
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
    }
}

/// A recoverable secp256k1 ECDSA signature: the 64-byte compact `r || s` and the
/// recovery id (0...3) needed to recover the signer's public key.
public struct RecoverableSignature: Sendable, Hashable {
    /// The 64-byte compact signature, `r || s` big-endian, low-`s`.
    public let compact: Data
    /// The recovery id (0...3).
    public let recoveryID: UInt8

    /// Creates a recoverable signature from its compact bytes and recovery id.
    public init(compact: Data, recoveryID: UInt8) {
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

/// A randomized libsecp256k1 context, owned for a signer's lifetime.
///
/// libsecp256k1 contexts are immutable after randomization and safe to use
/// concurrently for signing/verification, so this is `Sendable`; the C pointer is
/// freed in `deinit`.
final class Secp256k1Context: @unchecked Sendable {
    let raw: OpaquePointer

    init() {
        guard let context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            preconditionFailure("secp256k1_context_create failed (out of memory)")
        }
        // Randomize for side-channel hardening; does not affect signature output.
        let seed = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        _ = secp256k1_context_randomize(context, seed)
        raw = context
    }

    deinit { secp256k1_context_destroy(raw) }
}

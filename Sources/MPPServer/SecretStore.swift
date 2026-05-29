import Foundation

/// The server's challenge-id signing secret(s), with rotation support.
///
/// The challenge-id HMAC key (`draft-httpauth-payment-00` §5.1.2.1.1) is
/// root-of-trust material: anyone holding it can mint challenges that appear
/// server-issued for the realm. The MPP security guidance rotates it with overlap:
/// start minting under a new key, keep verifying the previous key during a short
/// overlap window so in-flight challenges still validate, then drop the old key
/// once those challenges have expired. `SecretStore` models that: ``current`` is
/// the key new challenges are minted under, and ``previous`` are the earlier keys
/// still inside their overlap window (accepted on verify, never used to mint).
///
/// Each secret is validated to be at least ``minimumSecretBytes`` long at
/// construction; a shorter key is rejected. `ChallengeSigner` is a pure HMAC
/// primitive that deliberately does not police key strength, so this is where the
/// minimum is enforced (an mpp-swift hardening policy: a key at least the
/// HMAC-SHA256 output size).
///
/// The secret bytes are not exposed publicly: only `ChallengeSigner` (this module)
/// reads them, and `Data`'s description is `"<n> bytes"`, so a store never leaks a
/// secret via reflection.
public struct SecretStore: Sendable {
    /// The minimum accepted secret length in bytes (the HMAC-SHA256 output size).
    public static let minimumSecretBytes = 32

    /// The most `previous` keys allowed. Verifying a credential tries the current
    /// key then each previous one, so an unbounded set would let an attacker
    /// spraying invalid ids force arbitrarily many HMACs per request; this caps
    /// that work. A rotation overlap needs only the immediately-previous key, so
    /// this ceiling is generous for staged or multi-region rollouts.
    public static let maximumPreviousKeys = 8

    /// The key new challenges are minted under.
    let current: Data
    /// Earlier keys still accepted on verify (most-recent first), for the rotation
    /// overlap window.
    let previous: [Data]

    /// The keys to try when verifying, in order: the current key, then the
    /// previous ones. Minting always uses ``current`` alone.
    var verificationSecrets: [Data] {
        [current] + previous
    }

    /// Creates a store from the current signing key and any previous keys still in
    /// their rotation overlap window (most-recent first).
    ///
    /// - Throws: ``ValidationError/tooShort(byteCount:)`` if any secret is shorter
    ///   than ``minimumSecretBytes``, or ``ValidationError/tooManyPreviousKeys(count:)``
    ///   if more than ``maximumPreviousKeys`` previous keys are given.
    public init(current: Data, previous: [Data] = []) throws(ValidationError) {
        guard previous.count <= Self.maximumPreviousKeys else {
            throw .tooManyPreviousKeys(count: previous.count)
        }
        try Self.validate(current)
        for secret in previous {
            try Self.validate(secret)
        }
        self.current = current
        self.previous = previous
    }

    private static func validate(_ secret: Data) throws(ValidationError) {
        guard secret.count >= minimumSecretBytes else {
            throw .tooShort(byteCount: secret.count)
        }
    }

    /// A reason a secret was rejected.
    public enum ValidationError: Error, Sendable, Hashable {
        /// The secret was shorter than ``SecretStore/minimumSecretBytes``.
        case tooShort(byteCount: Int)
        /// More than ``SecretStore/maximumPreviousKeys`` previous keys were given
        /// (an unbounded verify-key set is a denial-of-service lever).
        case tooManyPreviousKeys(count: Int)
    }
}

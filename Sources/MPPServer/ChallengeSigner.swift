import Crypto
import Foundation
import MPPCore

/// Mints and verifies a challenge ``Challenge/id`` with a server secret.
///
/// Per `draft-httpauth-payment-00` §5.1.2.1.1, the identifier is
/// `id = base64url(HMAC-SHA256(secret, bindingInput))` over the challenge's
/// ``Challenge/bindingInput`` (the seven positional slots, `id` excluded).
/// base64url is unpadded.
///
/// The secret never leaves the server; this type is the only place it is used to
/// produce or check an `id`. Verification is **constant-time** (the `id` is a
/// keyed, secret-derived MAC, so a non-constant-time compare could let an
/// attacker forge an `id` byte by byte).
///
/// Rotation: a signer built from a ``SecretStore`` mints under the store's current
/// key and verifies against the current key plus any previous keys in their overlap
/// window, so a challenge minted just before a rotation still validates during the
/// window (the MPP security guidance's rotate-with-overlap). A signer built from a
/// single `secret` is the no-rotation case (mint and verify with that one key).
public struct ChallengeSigner: Sendable {
    // Stored as Data, not SymmetricKey: Data is Sendable on every platform,
    // whereas swift-crypto's SymmetricKey is only Sendable on Darwin (via
    // CryptoKit). Data's description is "<n> bytes", so the secret never leaks
    // via reflection. Each key is wrapped per call (a cheap byte copy).
    private let current: Data
    private let verificationSecrets: [Data]

    /// Creates a signer over raw server-secret bytes (no rotation: mint and verify
    /// with this one key).
    ///
    /// The secret must be a strong, high-entropy key (at least 32 bytes for
    /// HMAC-SHA256). This type is a pure HMAC primitive and does not police key
    /// strength: validating the secret's length and provenance is ``SecretStore``'s
    /// job, the same way HMAC itself accepts a key of any length per RFC 2104.
    public init(secret: Data) {
        current = secret
        verificationSecrets = [secret]
    }

    /// Creates a rotation-aware signer: mints under the store's current key and
    /// verifies against the current key plus its previous (overlap-window) keys.
    public init(secretStore: SecretStore) {
        current = secretStore.current
        verificationSecrets = secretStore.verificationSecrets
    }

    /// The `id` for `challenge`: `base64url(HMAC-SHA256(secret, bindingInput))`,
    /// minted under the current key.
    ///
    /// The challenge's own ``Challenge/id`` is irrelevant (it is not part of
    /// ``Challenge/bindingInput``), so this can be called on a draft to mint its
    /// identifier.
    public func computeID(for challenge: Challenge) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(challenge.bindingInput.utf8),
            using: SymmetricKey(data: current)
        )
        return Base64URL.encode(Data(code))
    }

    /// Whether `challenge`'s ``Challenge/id`` is a valid HMAC of its binding input
    /// under the current key or any previous (overlap-window) key.
    ///
    /// Constant-time: each candidate key is checked with
    /// `HMAC.isValidAuthenticationCode`, never a string compare; the loop returns on
    /// the first match (which key matched is not secret). The `id` must be the
    /// **canonical** unpadded base64url of its MAC bytes (see below), otherwise it is
    /// rejected.
    public func verify(_ challenge: Challenge) -> Bool {
        // The id MUST be the canonical encoding of its bytes. base64url's final
        // character carries "don't care" low bits that a lenient decoder (Foundation's
        // Data(base64Encoded:)) ignores, so several distinct id strings decode to the
        // same MAC. Without this canonical check each variant would pass the byte-wise
        // MAC gate yet key a *distinct* replay slot (a single-use / double-spend
        // bypass). Re-encoding the decoded bytes and comparing the strings rejects
        // every non-canonical variant. Both operands are public (the supplied id and
        // its re-encoding), so this compare reveals nothing about the secret and does
        // not weaken the constant-time MAC check below.
        guard let mac = try? Base64URL.decode(challenge.id),
              Base64URL.encode(mac) == challenge.id else { return false }
        let input = Data(challenge.bindingInput.utf8)
        for secret in verificationSecrets where HMAC<SHA256>.isValidAuthenticationCode(
            mac, authenticating: input, using: SymmetricKey(data: secret)
        ) {
            return true
        }
        return false
    }
}

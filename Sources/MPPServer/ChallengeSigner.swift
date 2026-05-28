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
public struct ChallengeSigner: Sendable {
    // Stored as Data, not SymmetricKey: Data is Sendable on every platform,
    // whereas swift-crypto's SymmetricKey is only Sendable on Darwin (via
    // CryptoKit). Data's description is "<n> bytes", so the secret never leaks
    // via reflection. The key is wrapped per call (a cheap byte copy).
    private let secret: Data

    /// Creates a signer over raw server-secret bytes.
    public init(secret: Data) {
        self.secret = secret
    }

    private var key: SymmetricKey {
        SymmetricKey(data: secret)
    }

    /// The `id` for `challenge`: `base64url(HMAC-SHA256(secret, bindingInput))`.
    ///
    /// The challenge's own ``Challenge/id`` is irrelevant (it is not part of
    /// ``Challenge/bindingInput``), so this can be called on a draft to mint its
    /// identifier.
    public func computeID(for challenge: Challenge) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(challenge.bindingInput.utf8),
            using: key
        )
        return Base64URL.encode(Data(code))
    }

    /// Whether `challenge`'s ``Challenge/id`` is a valid HMAC of its binding
    /// input under this signer's secret.
    ///
    /// Constant-time: the recomputed MAC is checked with
    /// `HMAC.isValidAuthenticationCode`, never a string compare. An `id` that is
    /// not valid unpadded base64url cannot be a valid MAC, so it returns `false`.
    public func verify(_ challenge: Challenge) -> Bool {
        guard let mac = try? Base64URL.decode(challenge.id) else { return false }
        // Never compare the id with `==` / a string compare; the keyed MAC check
        // below is the constant-time path.
        return HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: Data(challenge.bindingInput.utf8),
            using: key
        )
    }
}

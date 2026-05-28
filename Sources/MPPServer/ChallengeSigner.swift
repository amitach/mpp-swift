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
    private let key: SymmetricKey

    /// Creates a signer over raw server-secret bytes.
    public init(secret: Data) {
        key = SymmetricKey(data: secret)
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
        return HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: Data(challenge.bindingInput.utf8),
            using: key
        )
    }
}

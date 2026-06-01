import Foundation
import MPPClient
import MPPCore
import MPPEVM
import MPPStripe
import MPPTempo

/// Builds the registered payment methods from the environment.
///
/// - Tempo: `MPP_PRIVATE_KEY`, a `0x`-prefixed 32-byte hex secp256k1 key, becomes a
///   ``TempoProofMethod`` (the zero-amount proof path).
/// - Stripe: `MPP_STRIPE_SPT`, a pre-obtained Shared Payment Token, becomes a
///   ``StripeChargeMethod``. The client presents an SPT, never a Stripe secret key (`sk_...`),
///   which is a server-side credential.
///
/// Each method is built with NO per-rail approval gate (Tempo defaults to `.allowAll`; the Stripe
/// token provider is a pure mint that never refuses), so the CLI's single consent point is the
/// injected ``PaymentAuthorizer`` and exactly one decision is made per payment. `MPP_SECRET_KEY` is
/// deliberately NOT read here - that is the server's verification secret, a different thing.
enum ClientKeyLoader {
    static func methods(from environment: [String: String]) throws -> [any PaymentMethodClient] {
        var methods: [any PaymentMethodClient] = []

        if let keyHex = environment["MPP_PRIVATE_KEY"] {
            guard let key = Data(hexPrefixed: keyHex) else { throw CLIError.invalidPrivateKey }
            let signer: Secp256k1Signer
            do {
                signer = try Secp256k1Signer(privateKey: key)
            } catch {
                throw CLIError.invalidPrivateKey
            }
            guard let tempo = TempoProofMethod(signer: signer)
            else { throw CLIError.invalidPrivateKey }
            methods.append(tempo)
        }

        if let spt = environment["MPP_STRIPE_SPT"] {
            methods.append(StripeChargeMethod(tokenProvider: StripeTokenProvider { _ in spt }))
        }

        return methods
    }
}

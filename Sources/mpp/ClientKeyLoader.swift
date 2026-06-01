import Foundation
import MPPAuth
import MPPClient
import MPPCore
import MPPEVM
import MPPStripe
import MPPTempo

/// Builds the registered payment methods from a named account or the environment.
///
/// - Tempo: from a stored account's key (`--account`, retrieval may prompt for Touch ID) or, with
///   no account, `MPP_PRIVATE_KEY` (a `0x`-prefixed 32-byte hex secp256k1 key) ->
/// ``TempoProofMethod``.
/// - Stripe: `MPP_STRIPE_SPT`, a pre-obtained Shared Payment Token, becomes a
/// ``StripeChargeMethod``.
///   The client presents an SPT, never a Stripe secret key (`sk_...`), which is a server-side
/// value.
///
/// Each method is built with NO per-rail approval gate (Tempo `.allowAll`; the Stripe token
/// provider
/// is a pure mint), so the CLI's single consent point is the injected ``PaymentAuthorizer``.
/// `MPP_SECRET_KEY` is deliberately NOT read here - that is the server's verification secret.
enum ClientKeyLoader {
    /// Env-only methods (the headless path); equivalent to no `--account`.
    static func methods(from environment: [String: String]) throws -> [any PaymentMethodClient] {
        try methods(account: nil, store: nil, environment: environment)
    }

    static func methods(
        account: String?,
        store: (any AccountStore)?,
        environment: [String: String]
    ) throws -> [any PaymentMethodClient] {
        var methods: [any PaymentMethodClient] = []

        if let account {
            guard let store else { throw CLIError.accountsUnsupported }
            let key: Data
            do {
                key = try store.privateKey(name: account)
            } catch let error as AccountStoreError {
                if case .notFound = error { throw CLIError.noPaymentMethod }
                throw error
            }
            try methods.append(tempoMethod(forKey: key))
        } else if let keyHex = environment["MPP_PRIVATE_KEY"] {
            guard let key = Data(hexPrefixed: keyHex) else { throw CLIError.invalidPrivateKey }
            try methods.append(tempoMethod(forKey: key))
        }

        if let spt = environment["MPP_STRIPE_SPT"] {
            methods.append(StripeChargeMethod(tokenProvider: StripeTokenProvider { _ in spt }))
        }

        return methods
    }

    private static func tempoMethod(forKey key: Data) throws -> any PaymentMethodClient {
        let signer: Secp256k1Signer
        do {
            signer = try Secp256k1Signer(privateKey: key)
        } catch {
            throw CLIError.invalidPrivateKey
        }
        guard let tempo = TempoProofMethod(signer: signer) else { throw CLIError.invalidPrivateKey }
        return tempo
    }
}

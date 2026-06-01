import Foundation
import MPPEVM

/// The inputs for one recurring subscription charge (besides the held fee parameters and
/// the chain id): the access key that signs the transaction, the TIP-20 `currency`, the
/// `recipient`, the per-period `amount` (decimal base-units string), the attribution
/// `memo` (32 bytes), and the serialized signed key authorization on the *provisioning*
/// charge (`nil` once the access key is provisioned on-chain).
///
/// Declared here (not in the FFI target) so the seam below and its caller (the renewal
/// engine) can name the inputs without depending on the `0x76` transaction layer; the
/// concrete FFI builder reuses this type verbatim.
///
/// - Important: `accessKeyPrivateKey` is secret key material. It is supplied per charge by
///   the caller (which holds it in its access-key store) and must never be logged.
public struct TempoSubscriptionChargeParameters: Sendable {
    /// The 32-byte secp256k1 private key of the access key the subscription delegated; it
    /// signs (and pays gas for) the charge transaction.
    public let accessKeyPrivateKey: Data
    /// The TIP-20 token the recurring transfer moves.
    public let currency: EthereumAddress
    /// The payee the recurring transfer is scoped to.
    public let recipient: EthereumAddress
    /// The per-period charge, as a base-10 `u256` string.
    public let amount: String
    /// The 32-byte MPP attribution memo carried by `transferWithMemo`.
    public let memo: Data
    /// The serialized signed `TempoKeyAuthorization` to attach on the provisioning charge
    /// (it adds the access key to the on-chain keychain), or `nil` on later charges.
    public let keyAuthorization: Data?

    /// Creates the charge inputs.
    public init(
        accessKeyPrivateKey: Data,
        currency: EthereumAddress,
        recipient: EthereumAddress,
        amount: String,
        memo: Data,
        keyAuthorization: Data?
    ) {
        self.accessKeyPrivateKey = accessKeyPrivateKey
        self.currency = currency
        self.recipient = recipient
        self.amount = amount
        self.memo = memo
        self.keyAuthorization = keyAuthorization
    }
}

/// Builds the signed Tempo `0x76` transaction for one recurring subscription charge: a
/// single `currency.transferWithMemo(recipient, amount, memo)` call, signed by the access
/// key the subscription delegated. On the provisioning charge the signed key authorization
/// is attached (the chain adds the access key to the `AccountKeychain` precompile before
/// verifying this tx's signature); later charges omit it.
///
/// It is a seam (mirroring ``TempoOpenTxBuilder``) so the renewal engine stays free of the
/// transaction-builder dependency: the concrete implementation (the FFI binding to
/// `tempo-primitives`) holds the fee parameters and a nonce reader and is injected; tests
/// inject a stub. Unlike the channel builders, the *signing key is per charge* (the access
/// key) and travels in ``TempoSubscriptionChargeParameters``, not in construction.
public protocol TempoSubscriptionChargeTxBuilder: Sendable {
    /// Returns the serialized, signed `0x76` transaction for the charge described by
    /// `parameters` on chain `chainID`, ready to broadcast via `eth_sendRawTransaction`.
    func buildSubscriptionChargeTransaction(
        _ parameters: TempoSubscriptionChargeParameters, chainID: UInt64
    ) async throws -> Data
}

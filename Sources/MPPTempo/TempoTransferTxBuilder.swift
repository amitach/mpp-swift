import Foundation
import MPPEVM

/// The inputs for one settled-charge transfer (besides the held fee parameters and the chain id):
/// the payer that signs and pays, the TIP-20 `currency`, the `recipient`, the `amount` (decimal
/// base-units string), and the 32-byte attribution `memo`.
///
/// Declared here (not in the FFI target) so the seam below and its caller (the charge client) can
/// name the inputs without depending on the `0x76` transaction layer; the concrete FFI builder
/// reuses this type verbatim.
///
/// Unlike a subscription charge, the payer signs the transfer **directly** (there is no access key,
/// so one signing key and no key authorization). `payer` is the address the transfer executes for:
/// both the signer (its private key) and the nonce account, supplied together so the builder need
/// not derive one from the other.
///
/// - Important: `payerPrivateKey` is secret key material. It is supplied per charge by the caller
///   (which holds it in its key store) and must never be logged.
public struct TempoTransferParameters: Sendable {
    /// The 32-byte secp256k1 private key of the payer; it signs the transfer directly.
    public let payerPrivateKey: Data
    /// The payer account the transfer executes for (the address of ``payerPrivateKey``); the
    /// builder reads its nonce.
    public let payer: EthereumAddress
    /// The TIP-20 token the transfer moves.
    public let currency: EthereumAddress
    /// The payee the transfer is scoped to.
    public let recipient: EthereumAddress
    /// The charge amount, as a base-10 `u256` string.
    public let amount: String
    /// The 32-byte MPP attribution memo carried by `transferWithMemo` (see ``Attribution``).
    public let memo: Data
    /// The charge's submission mode, per `draft-tempo-charge-00`:
    /// - `nil` -- **push**: a sequential-nonce tx the payer broadcasts itself (the `hash`
    ///   credential); the builder reads ``payer``'s nonce.
    /// - a unix-seconds deadline (at most 30s out) -- **pull**: an expiring-nonce tx the 402 server
    ///   broadcasts within the window (the `transaction` credential). The sequential nonce is
    ///   unused -- an expiring-nonce tx is replay-guarded by its hash.
    public let validBefore: UInt64?

    /// Creates the transfer inputs. `validBefore` defaults to `nil` (push mode).
    public init(
        payerPrivateKey: Data,
        payer: EthereumAddress,
        currency: EthereumAddress,
        recipient: EthereumAddress,
        amount: String,
        memo: Data,
        validBefore: UInt64? = nil
    ) {
        self.payerPrivateKey = payerPrivateKey
        self.payer = payer
        self.currency = currency
        self.recipient = recipient
        self.amount = amount
        self.memo = memo
        self.validBefore = validBefore
    }
}

/// Builds the signed Tempo `0x76` transaction for a one-time settled charge: a single
/// `currency.transferWithMemo(recipient, amount, memo)` call, signed **directly by the payer**
/// (`draft-tempo-charge-00`).
///
/// It is a seam (mirroring ``TempoSubscriptionChargeTxBuilder``) so the charge client stays free of
/// the transaction-builder dependency: the concrete implementation (the FFI binding to
/// `tempo-primitives`) holds the fee parameters and a nonce reader and is injected; tests inject a
/// stub.
public protocol TempoTransferTxBuilder: Sendable {
    /// Returns the serialized, signed `0x76` transaction for the transfer described by `parameters`
    /// on chain `chainID`, ready to broadcast via `eth_sendRawTransaction`.
    func buildTransferTransaction(
        _ parameters: TempoTransferParameters,
        chainID: UInt64
    ) async throws -> Data
}

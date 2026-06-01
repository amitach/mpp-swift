import Foundation
import MPPEVM
import MPPTempo

/// The concrete on-chain ``SubscriptionRenewer``: charges one billing period by submitting the
/// recurring `transferWithMemo` the subscription's key authorization permits, signed by the
/// server-held access key.
///
/// It wires the vertical's pieces behind injected seams (so it stays hermetically testable):
/// - ``AccessKeyStore`` supplies the access-key private key for the subscription's `lookupKey`;
/// - ``Attribution`` builds the on-chain memo, binding the charge to its idempotency reference;
/// - a ``TempoSubscriptionChargeTxBuilder`` builds + signs the `0x76` `transferWithMemo` tx;
/// - `submit` broadcasts it and returns the receipt (production passes
///   `EVMRPC.sendRawTransactionSync`; tests pass a stub).
///
/// The **first** charge (nothing charged yet, `lastChargedPeriod == nil`) attaches the signed key
/// authorization so the chain provisions the access key into its keychain; later charges omit it
/// (the key is already provisioned). This matches the activation model where the verifier does not
/// settle period 0, so the renewal engine's first charge is the provisioning one.
public struct TempoSubscriptionRenewer: SubscriptionRenewer {
    private let builder: any TempoSubscriptionChargeTxBuilder
    private let accessKeys: any AccessKeyStore
    private let serverId: String
    private let submit: @Sendable (Data) async throws -> TransactionReceipt

    /// Creates the renewer.
    /// - Parameters:
    ///   - builder: builds + signs the `transferWithMemo` charge transaction.
    ///   - accessKeys: supplies the access-key private key per `lookupKey`.
    ///   - serverId: the server identity baked into the attribution memo.
    ///   - submit: broadcasts the signed tx and returns its receipt (typically
    ///     `{ try await rpc.sendRawTransactionSync($0) }`).
    public init(
        builder: any TempoSubscriptionChargeTxBuilder,
        accessKeys: any AccessKeyStore,
        serverId: String,
        submit: @escaping @Sendable (Data) async throws -> TransactionReceipt
    ) {
        self.builder = builder
        self.accessKeys = accessKeys
        self.serverId = serverId
        self.submit = submit
    }

    /// Charges `period` of `record`, returning the settled transaction hash.
    ///
    /// `period` is encoded in `idempotencyReference` (the engine's stable
    /// `renewal:{id}:{period}` key), which also seeds the memo's nonce, so the charge is bound to
    /// the exact period without a separate parameter.
    ///
    /// - Throws: ``Error/accessKeyMissing`` if the subscription has no provisioned access key, or
    ///   ``Error/chargeReverted(_:)`` if the transaction mined but reverted (the engine then
    ///   releases its claim so a later attempt retries).
    public func charge(
        _ record: SubscriptionRecord,
        period _: Int,
        idempotencyReference: String
    ) async throws -> String {
        guard let accessKeyPrivateKey = await accessKeys.privateKey(forLookupKey: record.lookupKey)
        else {
            throw Error.accessKeyMissing
        }
        // First charge provisions the access key on-chain (attach the authorization); later charges
        // omit it (already provisioned). lastChargedPeriod == nil means nothing has been charged
        // yet.
        let keyAuthorization = record.lastChargedPeriod == nil ? record.keyAuthorization : nil
        let parameters = TempoSubscriptionChargeParameters(
            accessKeyPrivateKey: accessKeyPrivateKey,
            currency: record.currency,
            recipient: record.recipient,
            amount: record.amount.rawValue,
            memo: Attribution.encode(serverId: serverId, challengeId: idempotencyReference),
            keyAuthorization: keyAuthorization
        )
        let raw = try await builder.buildSubscriptionChargeTransaction(
            parameters, chainID: record.chainID
        )
        let receipt = try await submit(raw)
        guard receipt.succeeded else { throw Error.chargeReverted(receipt.transactionHash) }
        return receipt.transactionHash
    }

    /// A reason a charge did not settle.
    public enum Error: Swift.Error, Sendable, Hashable {
        /// No access-key private key is stored for the subscription's `lookupKey`.
        case accessKeyMissing
        /// The transaction mined but reverted (the carried hash).
        case chargeReverted(String)
    }
}

import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo

/// The on-chain operations the settled-charge verifier needs: read a receipt (push/`hash` mode,
/// where the client already broadcast) or broadcast a signed transaction (pull/`transaction` mode,
/// where the server broadcasts). A seam so the verifier stays free of a concrete transport;
/// ``RPCChargeSettlement`` is the live `EVMRPC` implementation and tests inject a stub.
public protocol TempoChargeSettlement: Sendable {
    /// The mined receipt for an already-broadcast transaction, or `nil` if it is not on-chain yet.
    func receipt(forTransactionHash hash: String) async throws -> TransactionReceipt?
    /// Broadcasts `rawTransaction` and returns its mined receipt (submit-and-wait).
    func broadcast(_ rawTransaction: Data) async throws -> TransactionReceipt
}

/// The live ``TempoChargeSettlement`` over ``EVMRPC`` (`eth_getTransactionReceipt` /
/// `eth_sendRawTransactionSync`).
public struct RPCChargeSettlement: TempoChargeSettlement {
    private let rpc: EVMRPC

    public init(rpc: EVMRPC) {
        self.rpc = rpc
    }

    public func receipt(forTransactionHash hash: String) async throws -> TransactionReceipt? {
        try await rpc.transactionReceipt(hash)
    }

    public func broadcast(_ rawTransaction: Data) async throws -> TransactionReceipt {
        try await rpc.sendRawTransactionSync(rawTransaction)
    }
}

/// The server-side Tempo charge method for a **non-zero settled transfer**: the verify counterpart
/// to ``TempoSettledChargeMethod`` (`draft-tempo-charge-00`).
///
/// It settles a `tempo` / `charge` challenge with a non-zero `amount` by confirming the transfer
/// happened on-chain. For a `hash` credential (push) it reads the named transaction's receipt; for
/// a
/// `transaction` credential (pull) it broadcasts the signed transaction and waits for the receipt.
/// In both cases it then requires:
/// - the transaction **succeeded** (a revert is not a payment), and
/// - a `TransferWithMemo` log whose **currency, `from` (the credential's `did:pkh` payer),
///   `recipient`, and `amount`** match the challenge, and
/// - a matching **memo**: the server-pinned `methodDetails.memo` exactly, or -- for an
///   auto-generated memo -- one **bound to this realm and challenge** (``Attribution/matches``), so
///   a transfer's hash cannot be replayed against a different challenge.
///
/// Finally it **single-uses the transaction hash** via the ``ReplayStore``: the on-chain check is a
/// read, so concurrent verifiers may both confirm the same valid transfer, but the atomic
/// `consume` admits exactly one -- a settled transfer pays for one resource.
///
/// - Important: this proves a transfer **settled on-chain for this challenge**; a caller gating on
///   identity must still authorize the payer out of band.
public struct TempoSettledChargeVerifier: PaymentMethodServer {
    private let settlement: any TempoChargeSettlement
    private let replayStore: any ReplayStore
    private let defaultChainId: UInt64

    /// Creates the verifier.
    /// - Parameters:
    ///   - settlement: reads/broadcasts on-chain (``RPCChargeSettlement`` in production).
    ///   - replayStore: enforces single-use of a settled transaction hash.
    ///   - defaultChainId: the chain to verify against when the challenge omits
    ///     `methodDetails.chainId` (defaults to ``TempoChain/mainnet``).
    public init(
        settlement: any TempoChargeSettlement,
        replayStore: any ReplayStore,
        defaultChainId: UInt64 = TempoChain.mainnet
    ) {
        self.settlement = settlement
        self.replayStore = replayStore
        self.defaultChainId = defaultChainId
    }

    /// Whether this is a `tempo` / `charge` challenge with a decodable **non-zero** request.
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == TempoMethod.name, challenge.intent == .charge,
              let request = try? TempoChargeRequest(challenge: challenge), !request.isZeroAmount
        else { return false }
        return true
    }

    /// Verifies the settled charge carried by `credential` and mints its receipt (whose `reference`
    /// is the settled transaction hash).
    public func verify(_ credential: Credential, now: Date) async throws(VerifyError) -> Receipt {
        let challenge = credential.challenge
        let request: TempoChargeRequest
        do {
            request = try TempoChargeRequest(challenge: challenge)
        } catch {
            throw .malformedRequest(error)
        }
        guard !request.isZeroAmount else { throw .notASettledCharge }
        guard let currencyHex = request.currency,
              let currency = EthereumAddress(hex: currencyHex)
        else { throw .missingOrInvalidCurrency }
        guard let recipientHex = request.recipient,
              let recipient = EthereumAddress(hex: recipientHex)
        else { throw .missingOrInvalidRecipient }
        guard let source = credential.source, let parsed = ProofSource.parse(source) else {
            throw .invalidSource
        }
        let chainId = request.chainId ?? defaultChainId
        guard parsed.chainId == chainId else { throw .chainIdMismatch }

        let receipt = try await settle(credential.payload)
        guard receipt.succeeded else { throw .reverted(receipt.transactionHash) }
        let expected = ExpectedTransfer(
            currency: currency, from: parsed.address, recipient: recipient, amount: request.amount
        )
        try requireMatchingTransfer(
            in: receipt, expected: expected, request: request, challenge: challenge
        )

        // Single-use: the receipt is verified, so consume the hash atomically -- first wins.
        guard await replayStore.consume(receipt.transactionHash) else {
            throw .alreadySettled(receipt.transactionHash)
        }
        return Receipt(
            method: challenge.method, timestamp: RFC3339DateTime(date: now),
            reference: receipt.transactionHash
        )
    }

    /// Obtains the receipt for the credential's mode: read it (`hash`) or broadcast it
    /// (`transaction`).
    private func settle(_ payload: [String: JSONValue]) async throws(VerifyError)
        -> TransactionReceipt {
        switch payload["type"]?.stringValue {
        case "hash":
            guard let hash = payload["hash"]?.stringValue else { throw .missingField("hash") }
            let receipt: TransactionReceipt?
            do {
                receipt = try await settlement.receipt(forTransactionHash: hash)
            } catch {
                throw .chainUnavailable(String(describing: error))
            }
            guard let receipt else { throw .transactionNotFound }
            // Defense in depth: the receipt must be for the hash the client named, so the
            // single-use consume and the minted reference bind to the presented transaction -- a
            // misbehaving or proxied RPC cannot substitute a receipt for a different tx.
            guard receipt.transactionHash.caseInsensitiveCompare(hash) == .orderedSame else {
                throw .receiptHashMismatch
            }
            return receipt
        case "transaction":
            guard let hex = payload["signature"]?.stringValue
            else { throw .missingField("signature") }
            guard let raw = Data(hexPrefixed: hex) else { throw .malformedSignature }
            do {
                return try await settlement.broadcast(raw)
            } catch {
                throw .broadcastFailed(String(describing: error))
            }
        default:
            throw .unsupportedCredentialType
        }
    }

    /// Requires `receipt` to carry a `TransferWithMemo` log matching the challenge's
    /// currency/from/recipient/amount **and** an acceptable memo
    /// (``memoAccepted(_:request:challenge:)``).
    ///
    /// It scans **all** logs rather than the first financial match: a transaction may carry several
    /// transfers with identical currency/from/recipient/amount but different memos (e.g. a batched
    /// or multi-call tx), and the charge settles iff one of them carries the right memo. This
    /// mirrors the reference SDK's `assertTransferLogs`, which folds the memo into the match.
    ///
    /// - Throws: ``VerifyError/memoMismatch`` when a financially matching transfer existed but none
    ///   carried an acceptable memo (so the distinction survives), else
    ///   ``VerifyError/noMatchingTransfer`` when nothing matched the amount/parties at all.
    private func requireMatchingTransfer(
        in receipt: TransactionReceipt,
        expected: ExpectedTransfer,
        request: TempoChargeRequest,
        challenge: Challenge
    ) throws(VerifyError) {
        var sawFinancialMatch = false
        for log in receipt.logs {
            guard let transfer = TIP20TransferEvent.transferWithMemo(from: log),
                  expected.financiallyMatches(transfer) else { continue }
            sawFinancialMatch = true
            if memoAccepted(transfer.memo, request: request, challenge: challenge) { return }
        }
        throw sawFinancialMatch ? .memoMismatch : .noMatchingTransfer
    }

    /// The currency, payer, recipient, and amount a settled charge's transfer must carry (the
    /// memo is matched separately, since several transfers may share these financials).
    private struct ExpectedTransfer {
        let currency: EthereumAddress
        let from: EthereumAddress
        let recipient: EthereumAddress
        let amount: Amount

        /// Whether `transfer` moves this amount of this currency from this payer to this recipient.
        func financiallyMatches(_ transfer: TIP20Transfer) -> Bool {
            transfer.currency == currency && transfer.from == from
                && transfer.recipient == recipient && transfer.amount == amount
        }
    }

    /// Whether `memo` is acceptable for this charge: it must equal the server-pinned
    /// `methodDetails.memo` exactly, or -- when the charge auto-generated one -- be bound to this
    /// realm and challenge (``Attribution/matches``). A pinned memo that is not valid `0x`-hex
    /// (a server misconfiguration) accepts nothing.
    private func memoAccepted(
        _ memo: Data,
        request: TempoChargeRequest,
        challenge: Challenge
    ) -> Bool {
        if let pinnedHex = request.memo {
            guard let pinned = Data(hexPrefixed: pinnedHex) else { return false }
            return memo == pinned
        }
        return Attribution.matches(memo: memo, serverId: challenge.realm, challengeId: challenge.id)
    }

    /// A reason ``TempoSettledChargeVerifier`` rejected a credential.
    public enum VerifyError: Error, Sendable, Hashable {
        /// The challenge `request` could not be decoded.
        case malformedRequest(TempoChargeRequest.DecodingFailure)
        /// The charge is zero-amount; that is the proof path (``TempoProofVerifier``).
        case notASettledCharge
        /// The request had no `currency`, or it was not an address.
        case missingOrInvalidCurrency
        /// The request had no `recipient`, or it was not an address.
        case missingOrInvalidRecipient
        /// The credential had no `source`, or it was not a valid `did:pkh:eip155` DID.
        case invalidSource
        /// The `source` chain did not match the challenge's chain.
        case chainIdMismatch
        /// The credential payload was missing a required field (named).
        case missingField(String)
        /// A `transaction` credential carried a `signature` that was not valid `0x`-hex (present
        /// but malformed, as distinct from absent).
        case malformedSignature
        /// The credential `type` was neither `hash` nor `transaction`.
        case unsupportedCredentialType
        /// The chain could not be read for a `hash` credential (carries the cause).
        case chainUnavailable(String)
        /// A `hash` credential named a transaction that is not on-chain.
        case transactionNotFound
        /// The receipt the RPC returned was for a different transaction than the `hash` credential
        /// named (a misbehaving or proxied RPC); the named transfer was not confirmed as itself.
        case receiptHashMismatch
        /// A `transaction` credential could not be broadcast (carries the cause).
        case broadcastFailed(String)
        /// The transaction reverted (its hash is carried); a reverted transfer is not a payment.
        case reverted(String)
        /// No `TransferWithMemo` log matched the challenge's currency/from/recipient/amount.
        case noMatchingTransfer
        /// The on-chain memo did not match the pinned or challenge-bound expectation.
        case memoMismatch
        /// The transaction hash was already used to settle a charge (single-use).
        case alreadySettled(String)
    }
}

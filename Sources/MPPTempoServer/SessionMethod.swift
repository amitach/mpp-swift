import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo

/// The server side of a Tempo pay-as-you-go session: a ``PaymentMethodServer`` that
/// settles `tempo` / `session` credentials over a payment channel.
///
/// A session credential carries one of four channel-lifecycle actions (matching the
/// reference SDKs):
/// - `open`: broadcast the client's channel-open transaction, validate the funded
///   channel on-chain, and record it; then charge the request.
/// - `voucher`: accept a cumulative voucher (bounds-checked against the on-chain
///   deposit/settled amount and the highest already accepted, signature verified
///   against the channel's authorized signer), then charge the request.
/// - `topUp`: broadcast a deposit top-up and refresh the recorded deposit.
/// - `close`: settle the highest voucher on-chain and finalize the channel.
///
/// On-chain reads and writes go through an injected ``ChannelStateProvider`` (the
/// operator's RPC, stubbed in tests); the off-chain accounting is the injected
/// ``ChannelStore``. The method holds no RPC dependency itself.
public struct SessionMethod: PaymentMethodServer {
    /// A reason a session action was rejected.
    public enum SessionError: Error, Sendable, Hashable {
        case malformedPayload
        case malformedRequest
        case missingEscrow
        /// The channel is finalized, closing, or fully settled on-chain.
        case channelClosed(reason: String)
        /// The voucher amount is at or below the on-chain settled amount.
        case belowSettled
        /// The voucher amount exceeds the on-chain deposit.
        case exceedsDeposit
        /// The voucher amount is below the highest already accepted (not monotonic).
        case belowHighestVoucher
        case invalidVoucherSignature
        /// The voucher's increase over the previous highest is below the minimum.
        case deltaTooSmall
        case channelNotFound
        /// The on-chain channel does not match the server's route (payee / token).
        case onChainMismatch(reason: String)
        case insufficientBalance
    }

    private let provider: any ChannelStateProvider
    private let store: any ChannelStore
    private let defaultChainID: UInt64
    private let minVoucherDelta: ChannelAmount

    public init(
        provider: any ChannelStateProvider,
        store: any ChannelStore,
        defaultChainID: UInt64 = TempoChain.mainnet,
        minVoucherDelta: ChannelAmount = .zero
    ) {
        self.provider = provider
        self.store = store
        self.defaultChainID = defaultChainID
        self.minVoucherDelta = minVoucherDelta
    }

    public func supports(_ challenge: Challenge) -> Bool {
        challenge.method == TempoMethod.name && challenge.intent == .session
    }

    public func verify(_ credential: Credential, now: Date) async throws -> Receipt {
        guard let action = SessionAction.parse(credential.payload) else {
            throw SessionError.malformedPayload
        }
        let challenge = credential.challenge
        guard let request = try? TempoChargeRequest(challenge: challenge) else {
            throw SessionError.malformedRequest
        }
        guard let escrowHex = request.escrowContract,
              let escrow = EthereumAddress(hex: escrowHex)
        else {
            throw SessionError.missingEscrow
        }
        // Fail closed: an amount that does not parse into the channel's uint128 must
        // reject the request, never silently charge zero (a free request).
        guard let chargeAmount = ChannelAmount(decimal: request.amount.rawValue) else {
            throw SessionError.malformedRequest
        }
        let context = Context(
            method: challenge.method,
            challengeID: challenge.id,
            escrow: escrow,
            chainID: request.chainId ?? defaultChainID,
            chargeAmount: chargeAmount,
            recipient: request.recipient.flatMap(EthereumAddress.init(hex:)),
            currency: request.currency.flatMap(EthereumAddress.init(hex:)),
            now: now
        )
        switch action {
        case let .voucher(fields): return try await acceptVoucher(fields, context)
        case let .open(fields): return try await openChannel(fields, context)
        case let .topUp(fields): return try await topUp(fields, context)
        case let .close(fields): return try await close(fields, context)
        }
    }

    // MARK: - voucher

    private func acceptVoucher(
        _ fields: SignedVoucherFields, _ context: Context
    ) async throws -> Receipt {
        let onChain = try await provider.channelState(
            channelID: fields.channelID, escrow: context.escrow, chainID: context.chainID
        )
        try ensureDrawable(onChain)
        let cumulative = try amount(fields.cumulativeAmount)
        if cumulative <= onChain.settled { throw SessionError.belowSettled }
        if cumulative > onChain.deposit { throw SessionError.exceedsDeposit }
        guard let channel = await store.channel(fields.channelID) else {
            throw SessionError.channelNotFound
        }
        if cumulative < channel.highestVoucherAmount { throw SessionError.belowHighestVoucher }
        try verifySignature(fields, expectedSigner: channel.authorizedSigner, context)

        // Advance the highest atomically: the delta gate re-reads the live highest
        // inside the store's serialization (TOCTOU-safe), so a concurrent voucher
        // cannot let a sub-`minVoucherDelta` increase slip through. Advance only when
        // strictly greater; an equal-cumulative replay does not advance but still
        // charges below, so it is bounded by the channel balance, never free.
        try await store.update(fields.channelID) { current in
            guard var channel = current else { return current }
            // Reject a voucher racing a close: a closing/finalized channel must not
            // advance the highest (consistent with deductFromChannel's guard), so the
            // off-chain record cannot drift above what gets settled.
            if channel.finalized { throw SessionError.channelClosed(reason: "finalized") }
            if channel.closing { throw SessionError.channelClosed(reason: "closing") }
            if cumulative > channel.highestVoucherAmount {
                guard let delta = cumulative.subtracting(channel.highestVoucherAmount),
                      delta >= minVoucherDelta
                else { throw SessionError.deltaTooSmall }
                channel.highestVoucherAmount = cumulative
                channel.highestVoucherSignature = fields.signature
            }
            return channel
        }
        let charged = try await chargeRequest(fields.channelID, context)
        return receipt(charged, context)
    }

    // MARK: - open

    private func openChannel(_ fields: OpenFields, _ context: Context) async throws -> Receipt {
        let (onChain, openTxHash) = try await provider.broadcastOpen(
            serializedTransaction: fields.transaction, channelID: fields.channelID,
            escrow: context.escrow, chainID: context.chainID
        )
        try validateOnChainChannel(onChain, context)
        let cumulative = try amount(fields.cumulativeAmount)
        if cumulative > onChain.deposit { throw SessionError.exceedsDeposit }
        if cumulative <= onChain.settled { throw SessionError.belowSettled }
        let signer = onChain.effectiveAuthorizedSigner
        try verifySignature(fields.asVoucher, expectedSigner: signer, context)

        try await store.update(fields.channelID) { existing in
            if var channel = existing {
                if cumulative > channel.highestVoucherAmount {
                    channel.highestVoucherAmount = cumulative
                    channel.highestVoucherSignature = fields.signature
                }
                channel.deposit = onChain.deposit
                if onChain.settled > channel.settledOnChain {
                    channel.settledOnChain = onChain.settled
                }
                // Invariant: spent >= on-chain settled. Raising spent to the settled
                // amount keeps available (highest - spent) from overstating the
                // drawable balance after an external settlement advanced the channel.
                if channel.settledOnChain > channel.spent {
                    channel.spent = channel.settledOnChain
                }
                channel.authorizedSigner = signer
                return channel
            }
            return ChannelState(
                channelID: fields.channelID, chainID: context.chainID,
                escrowContract: context.escrow,
                payer: onChain.payer, payee: onChain.payee, token: onChain.token,
                authorizedSigner: signer, deposit: onChain.deposit, settledOnChain: onChain.settled,
                highestVoucherAmount: cumulative, highestVoucherSignature: fields.signature,
                spent: onChain.settled, units: 0
            )
        }
        let charged = try await chargeRequest(fields.channelID, context)
        return SessionReceipt.make(
            method: context.method, now: context.now, challengeID: context.challengeID,
            channel: charged, txHash: openTxHash
        )
    }

    // MARK: - topUp

    private func topUp(_ fields: TopUpFields, _ context: Context) async throws -> Receipt {
        let (onChain, txHash) = try await provider.broadcastTopUp(
            serializedTransaction: fields.transaction, channelID: fields.channelID,
            escrow: context.escrow, chainID: context.chainID
        )
        guard let updated = try await store.update(fields.channelID, { current in
            guard var channel = current else { return current }
            channel.deposit = onChain.deposit
            return channel
        }) else { throw SessionError.channelNotFound }
        return SessionReceipt.make(
            method: context.method, now: context.now, challengeID: context.challengeID,
            channel: updated, txHash: txHash
        )
    }

    // MARK: - close

    private func close(_ fields: SignedVoucherFields, _ context: Context) async throws -> Receipt {
        guard let channel = await store.channel(fields.channelID) else {
            throw SessionError.channelNotFound
        }
        if channel.finalized { throw SessionError.channelClosed(reason: "finalized") }
        // Verify the close voucher before mutating any state, so only the authorized
        // signer (not an attacker with a bogus signature) can freeze the channel.
        try verifySignature(fields, expectedSigner: channel.authorizedSigner, context)
        let clientCumulative = try amount(fields.cumulativeAmount)

        // Atomically claim the close: re-check finalized and set `closing` so concurrent
        // vouchers stop drawing (deductFromChannel rejects a closing channel) during the
        // async on-chain settlement window. Use this claimed snapshot for the settle
        // selection so the stored highest/signature are read under serialization.
        guard let claimed = try await store.update(fields.channelID, { current in
            guard var channel = current else { throw SessionError.channelNotFound }
            if channel.finalized { throw SessionError.channelClosed(reason: "finalized") }
            // Single-flight: a close already in progress must reject the second one,
            // else two concurrent closes both reach provider.settle and broadcast a
            // duplicate on-chain settlement.
            if channel.closing { throw SessionError.channelClosed(reason: "closing") }
            channel.closing = true
            return channel
        }) else { throw SessionError.channelNotFound }

        let (settleAmount, settleSignature) = settleSelection(
            clientCumulative: clientCumulative, clientSignature: fields.signature, claimed: claimed
        )
        guard let voucher = Voucher(
            channelID: fields.channelID, cumulativeAmount: settleAmount.decimalString
        ) else { throw SessionError.malformedPayload }
        // If settle throws, `closing` is left set (not rolled back): the broadcast may
        // have landed on-chain with a lost response, and re-opening the channel would
        // risk a double settlement. A failed close therefore parks the channel closing;
        // recovery is an explicit on-chain step (the escrow's forced-close/grace path),
        // and the robust read-settled-before-resettle retry lands with the concrete
        // RPC provider. Funds are never at risk (the escrow caps payout at the deposit).
        let txHash = try await provider.settle(
            channelID: fields.channelID, voucher: voucher, signature: settleSignature,
            escrow: context.escrow, chainID: context.chainID
        )
        let updated = try await store.update(fields.channelID) { current in
            guard var channel = current else { return current }
            if settleAmount > channel.settledOnChain { channel.settledOnChain = settleAmount }
            channel.finalized = true
            return channel
        }
        return SessionReceipt.make(
            method: context.method, now: context.now, challengeID: context.challengeID,
            channel: updated ?? claimed, txHash: txHash
        )
    }

    // MARK: - helpers

    private func amount(_ decimal: String) throws -> ChannelAmount {
        guard let value = ChannelAmount(decimal: decimal)
        else { throw SessionError.malformedPayload }
        return value
    }

    /// On-chain state that allows drawing a voucher (not finalized/closing/settled).
    private func ensureDrawable(_ onChain: OnChainChannel) throws {
        if onChain.finalized { throw SessionError.channelClosed(reason: "finalized") }
        if onChain
            .closeRequestedAt != 0 { throw SessionError.channelClosed(reason: "close requested") }
        // A zeroed deposit during settlement closes the window; treat as closed.
        if onChain.deposit == .zero { throw SessionError.channelClosed(reason: "settled") }
    }

    private func validateOnChainChannel(_ onChain: OnChainChannel, _ context: Context) throws {
        if onChain.deposit == .zero { throw SessionError.channelNotFound }
        if onChain.finalized { throw SessionError.channelClosed(reason: "finalized") }
        if onChain
            .closeRequestedAt != 0 { throw SessionError.channelClosed(reason: "close requested") }
        if let recipient = context.recipient, onChain.payee != recipient {
            throw SessionError.onChainMismatch(reason: "payee")
        }
        if let currency = context.currency, onChain.token != currency {
            throw SessionError.onChainMismatch(reason: "token")
        }
    }

    private func verifySignature(
        _ fields: SignedVoucherFields, expectedSigner: EthereumAddress, _ context: Context
    ) throws {
        guard
            let voucher = Voucher(
                channelID: fields.channelID, cumulativeAmount: fields.cumulativeAmount
            ),
            voucher.verify(
                escrowContract: context.escrow, chainId: context.chainID,
                signature: fields.signature, expectedSigner: expectedSigner
            )
        else { throw SessionError.invalidVoucherSignature }
    }

    /// Charges this request's amount against the channel (one unit), mapping the
    /// store's failures to session rejections.
    private func chargeRequest(_ channelID: Data, _ context: Context) async throws -> ChannelState {
        do {
            return try await deductFromChannel(
                store,
                channelID: channelID,
                amount: context.chargeAmount
            )
        } catch let error as ChannelError {
            switch error {
            case .insufficientBalance: throw SessionError.insufficientBalance
            case let .closed(reason): throw SessionError.channelClosed(reason: reason)
            case .notFound: throw SessionError.channelNotFound
            }
        }
    }

    private func receipt(_ channel: ChannelState, _ context: Context) -> Receipt {
        SessionReceipt.make(
            method: context.method, now: context.now, challengeID: context.challengeID,
            channel: channel
        )
    }
}

/// Per-request resolved context for a session action (the challenge's route + the
/// injected clock). File-scope so it does not count against the method's body length.
private struct Context {
    let method: MethodName
    let challengeID: String
    let escrow: EthereumAddress
    let chainID: UInt64
    let chargeAmount: ChannelAmount
    let recipient: EthereumAddress?
    let currency: EthereumAddress?
    let now: Date
}

/// Picks the voucher a `close` settles: the higher of the client's final voucher
/// and the server's stored highest accepted voucher (with its stored signature), so
/// a close can never settle below what the channel already drew. The final `else` is
/// unreachable (a stored highest above the client's amount always carries its
/// signature) and falls back to the already-verified client voucher defensively.
private func settleSelection(
    clientCumulative: ChannelAmount, clientSignature: Data, claimed: ChannelState
) -> (amount: ChannelAmount, signature: Data) {
    if clientCumulative >= claimed.highestVoucherAmount {
        return (clientCumulative, clientSignature)
    }
    if let storedSignature = claimed.highestVoucherSignature {
        return (claimed.highestVoucherAmount, storedSignature)
    }
    return (clientCumulative, clientSignature)
}

private extension OpenFields {
    /// The `{channelId, cumulativeAmount, signature}` view for signature verification.
    var asVoucher: SignedVoucherFields {
        SignedVoucherFields(
            channelID: channelID, cumulativeAmount: cumulativeAmount, signature: signature
        )
    }
}

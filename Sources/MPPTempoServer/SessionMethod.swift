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

    /// A session reuses one challenge across open / voucher / close; anti-replay is the
    /// monotonic cumulative the channel store enforces (not one-time challenge use), so the
    /// verifier must not consume the challenge id (it would reject every voucher after open).
    public var reusesChallenge: Bool {
        true
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
        let context = SessionContext(
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
        case let .voucher(fields):
            // Resolve the minimum delta only here: it gates voucher acceptance alone, so a
            // malformed per-challenge override must not also block a topUp or a channel close.
            let minDelta = try resolveMinVoucherDelta(request)
            return try await acceptVoucher(fields, context, minVoucherDelta: minDelta)
        case let .open(fields): return try await openChannel(fields, context)
        case let .topUp(fields): return try await topUp(fields, context)
        case let .close(fields): return try await close(fields, context)
        }
    }

    /// The minimum voucher delta for this challenge: the per-challenge
    /// `methodDetails.minVoucherDelta` override (a decimal base-units string) when set, else the
    /// verifier's static default (`init`). A present-but-unparseable override fails closed rather
    /// than silently using the default, since the value gates how little a voucher may advance.
    private func resolveMinVoucherDelta(
        _ request: TempoChargeRequest
    ) throws(SessionError) -> ChannelAmount {
        guard let raw = request.minVoucherDelta else { return minVoucherDelta }
        guard let parsed = ChannelAmount(decimal: raw) else { throw .malformedRequest }
        return parsed
    }

    // MARK: - voucher

    private func acceptVoucher(
        _ fields: SignedVoucherFields, _ context: SessionContext, minVoucherDelta: ChannelAmount
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
        // `authorizedSigner` is immutable per channel, so verifying the signature against the
        // pre-read value is race-free; the monotonic decision below is the part that must be
        // atomic.
        try verifySignature(fields, expectedSigner: channel.authorizedSigner, context)

        // The monotonic decision is atomic (serialized in the store update): a voucher EQUAL to the
        // highest is an idempotent replay (no new charge; via IdempotentVoucher, caught below; spec
        // §10.4 / mppx peer); a strictly lower one is rejected, a higher one charges once.
        do {
            try await store.update(fields.channelID) { current in
                guard var channel = current else { throw SessionError.channelNotFound }
                // Reject a voucher racing a close: a closing/finalized channel must not advance the
                // highest (consistent with deductFromChannel's guard).
                if let reason = channel.undrawableReason {
                    throw SessionError.channelClosed(reason: reason)
                }
                if cumulative == channel.highestVoucherAmount {
                    throw IdempotentVoucher(channel: channel)
                }
                guard cumulative > channel.highestVoucherAmount else {
                    throw SessionError.belowHighestVoucher
                }
                guard let delta = cumulative.subtracting(channel.highestVoucherAmount),
                      delta >= minVoucherDelta
                else { throw SessionError.deltaTooSmall }
                channel.highestVoucherAmount = cumulative
                channel.highestVoucherSignature = fields.signature
                return channel
            }
        } catch let replay as IdempotentVoucher {
            // An already-accepted cumulative: return a receipt for the unchanged channel, no
            // charge.
            return receipt(replay.channel, context)
        }
        // Reached only after a strictly-advancing voucher committed atomically: charge once.
        let charged = try await chargeSession(store, fields.channelID, context.chargeAmount)
        return receipt(charged, context)
    }

    // MARK: - open

    private func openChannel(
        _ fields: OpenFields,
        _ context: SessionContext
    ) async throws -> Receipt {
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
        let charged = try await chargeSession(store, fields.channelID, context.chargeAmount)
        return SessionReceipt.make(
            method: context.method, now: context.now, challengeID: context.challengeID,
            channel: charged, txHash: openTxHash
        )
    }

    // MARK: - topUp

    private func topUp(_ fields: TopUpFields, _ context: SessionContext) async throws -> Receipt {
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

    private func close(
        _ fields: SignedVoucherFields,
        _ context: SessionContext
    ) async throws -> Receipt {
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
            // Single-flight: reject a finalized channel and a close already in progress
            // (a second concurrent close would otherwise both reach provider.settle and
            // broadcast a duplicate on-chain settlement), then claim the close.
            if let reason = channel.undrawableReason {
                throw SessionError.channelClosed(reason: reason)
            }
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
}

// Private helpers, in an extension so they do not count against the struct's body-length limit.
extension SessionMethod {
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

    private func validateOnChainChannel(
        _ onChain: OnChainChannel,
        _ context: SessionContext
    ) throws {
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
        _ fields: SignedVoucherFields, expectedSigner: EthereumAddress, _ context: SessionContext
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

    private func receipt(_ channel: ChannelState, _ context: SessionContext) -> Receipt {
        SessionReceipt.make(
            method: context.method, now: context.now, challengeID: context.challengeID,
            channel: channel
        )
    }
}

/// Internal control-flow signal: a voucher whose cumulative equals the channel's current highest
/// is an idempotent replay. Thrown from inside the atomic store update (aborting its no-op write)
/// and caught by `acceptVoucher`, which returns a receipt for the unchanged channel without
/// charging again.
private struct IdempotentVoucher: Error {
    let channel: ChannelState
}

/// Charges a session request's `amount` against the channel, mapping store failures to session
/// rejections. File-scope so it does not count against the method's body length.
private func chargeSession(
    _ store: any ChannelStore, _ channelID: Data, _ amount: ChannelAmount
) async throws -> ChannelState {
    do {
        return try await deductFromChannel(store, channelID: channelID, amount: amount)
    } catch let error as ChannelError {
        switch error {
        case .insufficientBalance: throw SessionMethod.SessionError.insufficientBalance
        case let .closed(reason): throw SessionMethod.SessionError.channelClosed(reason: reason)
        case .notFound: throw SessionMethod.SessionError.channelNotFound
        }
    }
}

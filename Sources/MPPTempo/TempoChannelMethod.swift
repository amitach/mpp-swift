import Foundation
import MPPClient
import MPPCore
import MPPEVM

/// The Tempo channel payment method, client side: pays a `tempo` / `session` 402
/// challenge by opening a payment channel on the first charge to a recipient and
/// issuing off-chain vouchers on every charge after.
///
/// This is the faithful port of the reference mppx client's auto-charge flow
/// (`client/{Charge,Session,ChannelOps}.ts`). A `tempo` / `session` challenge names an
/// escrow, a payee (`recipient`), a token (`currency`), and the per-request `amount`.
/// The method keys an open channel by `(payee, token, escrow)`: the first charge builds
/// the signed `open` `0x76` transaction (via an injected ``TempoOpenTxBuilder``) plus an
/// initial voucher, and emits the `open` payload the server relays and settles; each
/// later charge to the same triple just signs a cumulative voucher and emits the
/// `voucher` payload (no transaction). The deposit for a new channel comes from the
/// injected `depositPolicy`, never from the charge amount.
///
/// It builds payloads but never broadcasts: the server relays the open transaction and
/// settles vouchers. The direct-on-chain path is ``MPPTempoFFI``'s `TempoChannelSession`.
///
/// Construction derives the wallet address from the signer's public key, so the
/// `did:pkh` source, the voucher signer, and the channel `payer`/`authorizedSigner` all
/// match the signing key.
public struct TempoChannelMethod: PaymentMethodClient {
    private let signer: Secp256k1Signer
    private let wallet: EthereumAddress
    private let openBuilder: any TempoOpenTxBuilder
    private let topUpBuilder: (any TempoTopUpTxBuilder)?
    private let channelReader: (any ChannelStateReading)?
    private let defaultChainId: UInt64
    private let depositPolicy: @Sendable (DepositContext) -> String?
    private let approval: TempoApprovalPolicy
    private let saltProvider: @Sendable () -> Data
    private let registry = TempoChannelRegistry()

    /// Creates the method.
    ///
    /// - Parameters:
    ///   - signer: the secp256k1 signer; its public key fixes the wallet (payer and
    ///     authorized signer) address and signs vouchers.
    ///   - openBuilder: builds the signed `open` `0x76` transaction (the FFI builder in
    ///     production; a stub in tests).
    ///   - defaultChainId: the chain used when the challenge omits `methodDetails.chainId`.
    ///     Defaults to ``TempoChain/mainnet``.
    ///   - depositPolicy: resolves the deposit for a NEW channel from the charge facts;
    ///     returning `nil` rejects the open (``TempoChannelMethodError/noDeposit``). The
    ///     deposit is never the charge amount.
    ///   - approval: the pre-sign spending control (defaults to
    ///     ``TempoApprovalPolicy/allowAll``), run on every charge.
    ///   - saltProvider: supplies the 32-byte channel salt for a new channel (defaults to
    ///     secure-random; injected for deterministic tests).
    ///   - topUpBuilder: builds the signed `topUp` `0x76` transaction; required only for
    ///     ``buildTopUp(for:additionalDeposit:)`` (nil rejects a top-up). Open + voucher +
    ///     close do not need it.
    ///   - channelReader: reads on-chain channel state to attach to a server-suggested
    ///     channel (`methodDetails.channelId`) instead of opening a fresh one; nil disables
    ///     recovery (the default - the method always opens for a key it has not seen).
    /// - Returns: `nil` only if a valid address cannot be derived from the signer.
    public init?(
        signer: Secp256k1Signer,
        openBuilder: any TempoOpenTxBuilder,
        defaultChainId: UInt64 = TempoChain.mainnet,
        depositPolicy: @escaping @Sendable (DepositContext) -> String?,
        approval: TempoApprovalPolicy = .allowAll,
        saltProvider: @escaping @Sendable () -> Data = {
            Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
        },
        topUpBuilder: (any TempoTopUpTxBuilder)? = nil,
        channelReader: (any ChannelStateReading)? = nil
    ) {
        guard let wallet = EthereumAddress(uncompressedPublicKey: signer.publicKey) else {
            return nil
        }
        self.signer = signer
        self.wallet = wallet
        self.openBuilder = openBuilder
        self.topUpBuilder = topUpBuilder
        self.channelReader = channelReader
        self.defaultChainId = defaultChainId
        self.depositPolicy = depositPolicy
        self.approval = approval
        self.saltProvider = saltProvider
    }

    /// The wallet (payer / authorized signer) derived from the signer.
    public var address: EthereumAddress {
        wallet
    }

    /// The `Accept-Payment` range this method satisfies: `tempo` / `session`. A client
    /// builds its advertisement from the union of its methods' ranges, so this stays
    /// derived rather than hardcoded.
    public var paymentRanges: [PaymentRange] {
        [Self.sessionRange]
    }

    /// Whether this is a `tempo` / `session` challenge with a decodable request that
    /// names an escrow, a payee (`recipient`), and a token (`currency`). A decode or
    /// field failure maps to `false`; the throwing path in ``buildCredential(for:)``
    /// surfaces the specific reason.
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == TempoMethod.name, challenge.intent == .session,
              let request = try? TempoChargeRequest(challenge: challenge),
              resolveSession(request) != nil
        else { return false }
        return true
    }

    /// Builds the channel credential for `challenge`: opens the channel (first charge) or
    /// vouchers against the open one, runs the approval gate first, and assembles the
    /// `open`/`voucher` payload with the `did:pkh` source.
    ///
    /// - Throws: ``TempoChannelMethodError`` for a wrong method/intent, a malformed or
    ///   non-session request, an over-range amount, a denied approval, a missing deposit,
    ///   an open-transaction failure, or a signing failure.
    public func buildCredential(for challenge: Challenge) async throws -> Credential {
        guard challenge.method == TempoMethod.name, challenge.intent == .session else {
            throw TempoChannelMethodError.wrongMethodOrIntent
        }
        let request: TempoChargeRequest
        do {
            request = try TempoChargeRequest(challenge: challenge)
        } catch {
            throw TempoChannelMethodError.malformedRequest(error)
        }
        guard let session = resolveSession(request) else {
            throw TempoChannelMethodError.notASession
        }
        guard let amount = ChannelAmount(decimal: request.amount.rawValue) else {
            throw TempoChannelMethodError.amountExceedsChannelRange
        }
        let chainId = request.chainId ?? defaultChainId
        try await runApproval(challenge, request, chainId)
        await recoverIfSuggested(session, chainId: chainId, request: request)
        let outcome = try await registry.charge(session.key(chainId: chainId), amount: amount) {
            try await openChannel(session, chainId: chainId, request: request)
        }
        return try assembleCredential(
            challenge,
            chainId: chainId,
            escrow: session.escrow,
            outcome: outcome
        )
    }

    /// Builds a `topUp` credential for the channel already open for `challenge`'s
    /// `(payee, token, escrow)`: a signed `[approve, topUp]` `0x76` transaction the server
    /// relays. Client-initiated channel management, not a charge response.
    ///
    /// - Throws: ``TempoChannelMethodError`` for a wrong method/intent, a non-session or
    ///   malformed request, no open channel for the key, a missing top-up builder, or a
    ///   build failure.
    public func buildTopUp(
        for challenge: Challenge,
        additionalDeposit: String
    ) async throws -> Credential {
        let (session, chainId) = try resolveForManagement(challenge)
        guard let topUpBuilder else { throw TempoChannelMethodError.topUpUnsupported }
        guard let open = await registry.openChannel(session.key(chainId: chainId)) else {
            throw TempoChannelMethodError.noOpenChannel
        }
        let transaction: Data
        do {
            transaction = try await topUpBuilder.buildTopUpTransaction(
                escrow: session.escrow, token: session.token, channelID: open.channelID,
                additionalDeposit: additionalDeposit, chainID: chainId
            )
        } catch {
            throw TempoChannelMethodError.topUpTransactionFailed(String(describing: error))
        }
        let payload: [String: JSONValue] = [
            "action": .string("topUp"),
            "type": .string("transaction"),
            "channelId": .string(open.channelID.hexPrefixed),
            "transaction": .string(transaction.hexPrefixed),
            "additionalDeposit": .string(additionalDeposit),
        ]
        return credential(challenge, chainId: chainId, payload: payload)
    }

    /// Builds a `close` credential settling the channel open for `challenge`'s key at its
    /// latest tracked cumulative (a signed voucher, no transaction: the server settles it
    /// on-chain). Removes the channel from the registry, so a later charge opens a fresh one.
    ///
    /// - Throws: ``TempoChannelMethodError`` for a wrong method/intent, a non-session or
    ///   malformed request, no open channel for the key, or a signing failure.
    public func buildClose(for challenge: Challenge) async throws -> Credential {
        let (session, chainId) = try resolveForManagement(challenge)
        guard let open = await registry.removeChannel(session.key(chainId: chainId)) else {
            throw TempoChannelMethodError.noOpenChannel
        }
        let signature = try signVoucher(
            open.channelID, open.cumulative, escrow: session.escrow, chainId: chainId
        )
        let payload = voucherPayload("close", open.channelID, open.cumulative, signature)
        return credential(challenge, chainId: chainId, payload: payload)
    }

    // MARK: - Internals

    /// Validates a management call (topUp/close) and resolves its session + chain.
    private func resolveForManagement(
        _ challenge: Challenge
    ) throws -> (session: ResolvedSession, chainId: UInt64) {
        guard challenge.method == TempoMethod.name, challenge.intent == .session else {
            throw TempoChannelMethodError.wrongMethodOrIntent
        }
        let request: TempoChargeRequest
        do {
            request = try TempoChargeRequest(challenge: challenge)
        } catch {
            throw TempoChannelMethodError.malformedRequest(error)
        }
        guard let session = resolveSession(request) else {
            throw TempoChannelMethodError.notASession
        }
        return (session, request.chainId ?? defaultChainId)
    }

    /// Wraps a payload as a `Credential` with the `did:pkh` source. Shared by the management
    /// ops; the auto-charge path uses ``assembleCredential(_:chainId:escrow:outcome:)``.
    private func credential(
        _ challenge: Challenge, chainId: UInt64, payload: [String: JSONValue]
    ) -> Credential {
        Credential(
            challenge: challenge,
            source: ProofSource.did(address: wallet, chainId: chainId),
            payload: payload
        )
    }

    /// If a `channelReader` is configured and the challenge suggests a `channelId` for a key
    /// with no open channel, reads it on-chain and (when it has a positive deposit and is not
    /// finalized) attaches it to the registry with the on-chain settled amount as the
    /// cumulative floor, so the charge vouchers against it instead of opening fresh. A read
    /// failure or an unusable channel is a no-op (the charge opens, matching the reference
    /// client when there is no explicit channel to reuse).
    private func recoverIfSuggested(
        _ session: ResolvedSession, chainId: UInt64, request: TempoChargeRequest
    ) async {
        guard let channelReader, let suggested = request.suggestedChannelID else { return }
        let key = session.key(chainId: chainId)
        guard await registry.openChannel(key) == nil else { return }
        guard let onChain = try? await channelReader.onChainChannel(
            channelID: suggested, escrow: session.escrow, chainID: chainId
        ), onChain.deposit > .zero, !onChain.finalized else { return }
        await registry.attach(key, channelID: suggested, cumulative: onChain.settled)
    }

    /// Runs the approval gate over the charge facts; throws if it rejects (before any
    /// signature is produced). Parity with ``TempoProofMethod``.
    private func runApproval(
        _ challenge: Challenge, _ request: TempoChargeRequest, _ chainId: UInt64
    ) async throws {
        let facts = ChargeApproval(
            challengeId: challenge.id, realm: challenge.realm, chainId: chainId,
            amount: request.amount, currency: request.currency, recipient: request.recipient,
            validUntil: challenge.expires
        )
        guard await approval.approves(facts) else { throw TempoChannelMethodError.approvalDenied }
    }

    /// Opens a channel: resolves the deposit, derives the channel id, and builds the
    /// signed open transaction. Run at most once per key by the registry.
    private func openChannel(
        _ session: ResolvedSession, chainId: UInt64, request: TempoChargeRequest
    ) async throws -> OpenedChannel {
        let context = DepositContext(
            payee: session.payee, token: session.token, escrow: session.escrow,
            chainId: chainId, chargeAmount: request.amount,
            suggestedDeposit: request.suggestedDeposit
        )
        guard let deposit = depositPolicy(context) else { throw TempoChannelMethodError.noDeposit }
        // Fail closed early: the deposit must be a canonical `uint128` (the escrow's type).
        // The tx builder would also reject a bad string, but as an opaque build failure;
        // validating here surfaces a precise error before deriving the channel or building.
        guard ChannelAmount(decimal: deposit) != nil else {
            throw TempoChannelMethodError.invalidDeposit
        }
        let salt = saltProvider()
        guard let parameters = Channel.Parameters(
            payer: wallet, payee: session.payee, token: session.token, salt: salt,
            authorizedSigner: wallet, escrowContract: session.escrow, chainId: chainId
        ) else {
            throw TempoChannelMethodError.invalidSalt
        }
        let openParameters = TempoOpenParameters(
            escrow: session.escrow, token: session.token, payee: session.payee,
            deposit: deposit, salt: salt, authorizedSigner: wallet
        )
        let transaction: Data
        do {
            transaction = try await openBuilder.buildOpenTransaction(
                openParameters,
                chainID: chainId
            )
        } catch {
            throw TempoChannelMethodError.openTransactionFailed(String(describing: error))
        }
        return OpenedChannel(channelID: Channel.id(parameters), transaction: transaction)
    }

    /// Signs the voucher for the outcome and wraps it as a `Credential` with the
    /// `did:pkh` source and the action payload the server's session method parses.
    private func assembleCredential(
        _ challenge: Challenge, chainId: UInt64, escrow: EthereumAddress, outcome: ChannelOutcome
    ) throws -> Credential {
        let payload: [String: JSONValue]
        switch outcome {
        case let .voucher(channelID, cumulative):
            let signature = try signVoucher(channelID, cumulative, escrow: escrow, chainId: chainId)
            payload = voucherPayload("voucher", channelID, cumulative, signature)
        case let .open(channelID, cumulative, transaction):
            let signature = try signVoucher(channelID, cumulative, escrow: escrow, chainId: chainId)
            var open = voucherPayload("open", channelID, cumulative, signature)
            // The open action carries the signed channel-open transaction for the server to
            // relay. `type: transaction` tags the payload as a transaction-bearing action
            // (per draft-tempo-charge, alongside topUp); the field is advisory for a server
            // that switches on `action`, but it is part of the canonical open payload.
            open["type"] = .string("transaction")
            open["transaction"] = .string(transaction.hexPrefixed)
            open["authorizedSigner"] = .string(wallet.checksummed)
            payload = open
        }
        return credential(challenge, chainId: chainId, payload: payload)
    }

    private func signVoucher(
        _ channelID: Data, _ cumulative: ChannelAmount, escrow: EthereumAddress, chainId: UInt64
    ) throws -> Data {
        guard let voucher = Voucher(
            channelID: channelID,
            cumulativeAmount: cumulative.decimalString
        ) else {
            throw TempoChannelMethodError.amountExceedsChannelRange
        }
        do {
            return try voucher.sign(escrowContract: escrow, chainId: chainId, with: signer)
        } catch {
            throw TempoChannelMethodError.signingFailed(error)
        }
    }

    /// The `{action, channelId, cumulativeAmount, signature}` shared by both payloads.
    /// `channelId`/`signature` are `0x`-prefixed hex; `cumulativeAmount` is decimal.
    private func voucherPayload(
        _ action: String, _ channelID: Data, _ cumulative: ChannelAmount, _ signature: Data
    ) -> [String: JSONValue] {
        [
            "action": .string(action),
            "channelId": .string(channelID.hexPrefixed),
            "cumulativeAmount": .string(cumulative.decimalString),
            "signature": .string(signature.hexPrefixed),
        ]
    }

    /// The `tempo` / `session` advertisement range, built once. The default quality is in
    /// range, so this construction cannot fail.
    private static let sessionRange: PaymentRange = {
        guard let range = try? PaymentRange(
            method: .value(TempoMethod.name), intent: .value(.session)
        ) else {
            preconditionFailure("tempo/session with default quality is a valid range")
        }
        return range
    }()
}

/// The escrow / payee / token a session challenge resolves to. File-scope (not nested in the
/// method) so it does not count against the method's type-body length.
private struct ResolvedSession {
    let escrow: EthereumAddress
    let payee: EthereumAddress
    let token: EthereumAddress
    /// The registry key for this channel on `chainId`. `chainId` is part of the key (unlike
    /// the reference client) because it binds the voucher's EIP-712 domain and the on-chain
    /// channel id: without it, the same `(payee, token, escrow)` on two chains would share one
    /// entry, and the second charge would voucher against the first chain's channel with the
    /// wrong domain. The key is internal client state (never on the wire), so this is a
    /// correctness fix with no protocol impact.
    func key(chainId: UInt64) -> ChannelKey {
        ChannelKey(payee: payee, token: token, escrow: escrow, chainId: chainId)
    }
}

/// Resolves the escrow / payee / token a session challenge names, or `nil` if any is absent
/// or not a valid address.
private func resolveSession(_ request: TempoChargeRequest) -> ResolvedSession? {
    guard let escrowHex = request.escrowContract, let escrow = EthereumAddress(hex: escrowHex),
          let payeeHex = request.recipient, let payee = EthereumAddress(hex: payeeHex),
          let tokenHex = request.currency, let token = EthereumAddress(hex: tokenHex)
    else { return nil }
    return ResolvedSession(escrow: escrow, payee: payee, token: token)
}

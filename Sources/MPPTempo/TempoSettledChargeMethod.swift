import Foundation
import MPPClient
import MPPCore
import MPPEVM

/// The Tempo charge payment method, client side, for a **non-zero settled transfer**, in both
/// submission modes (`draft-tempo-charge-00`).
///
/// It pays a `tempo` / `charge` challenge whose `amount` is non-zero by building a payer-signed
/// `currency.transferWithMemo(recipient, amount, memo)` `0x76` transaction and presenting one of
/// two
/// credentials, by mode:
/// - **pull** (`transaction`): an *expiring-nonce* tx (`validBefore = min(now + window, expiry)`)
/// the
///   `402` server broadcasts within the window. Preferred whenever the server allows it; no
///   broadcaster needed.
/// - **push** (`hash`): a sequential-nonce tx this client broadcasts itself (via an injected
///   ``TempoTransferBroadcaster``), presenting the mined hash. Used when the server offers only
/// push.
///
/// The zero-amount proof path is ``TempoProofMethod``.
///
/// The transaction is built over an injected ``TempoTransferTxBuilder`` (the concrete FFI builder
/// holds the fee parameters), so this type only routes, gates, derives the attribution memo, and
/// assembles the ``Credential``. The payer address is derived from the signing key, so the
/// `did:pkh` source always matches it.
public struct TempoSettledChargeMethod: PaymentMethodClient {
    /// The default pull-mode validity window: the reference client signs a tx valid for ~25
    /// seconds.
    public static let defaultWindowSeconds: UInt64 = 25

    /// The submission mode for one charge (`draft-tempo-charge-00`).
    private enum Mode { case pull, push }

    private let payerPrivateKey: Data
    private let payer: EthereumAddress
    private let transferBuilder: any TempoTransferTxBuilder
    private let broadcaster: (any TempoTransferBroadcaster)?
    private let clientId: String?
    private let defaultChainId: UInt64
    private let approval: TempoApprovalPolicy
    private let windowSeconds: UInt64
    private let now: @Sendable () -> Date

    /// Creates the method over the payer's signing key and a transfer-tx builder.
    ///
    /// - Parameters:
    ///   - payerPrivateKey: the 32-byte secp256k1 key that signs the transfer and is the `did:pkh`
    ///     source; its public key fixes the payer address.
    ///   - transferBuilder: builds the signed `0x76` transfer (the FFI builder holds the fee/nonce
    ///     infrastructure).
    ///   - broadcaster: submits the transaction for **push** mode (the `hash` credential). When
    ///     `nil` (the default), only **pull** mode (the `transaction` credential) is offered, so a
    ///     push-only challenge is unsupported. Pull is preferred whenever the server allows it.
    ///   - clientId: an optional client identity folded into the attribution memo; `nil` is
    ///     anonymous.
    ///   - defaultChainId: the chain to use when the challenge's `methodDetails.chainId` is absent.
    ///   - approval: the pre-sign spending control (defaults to ``TempoApprovalPolicy/allowAll``).
    ///   - windowSeconds: the pull-mode validity window (defaults to ``defaultWindowSeconds``).
    ///   - now: the clock used to compute `validBefore` (defaults to `Date.init`).
    /// - Returns: `nil` only if a valid payer address cannot be derived from `payerPrivateKey`
    ///   (which does not happen for a valid 32-byte key).
    public init?(
        payerPrivateKey: Data,
        transferBuilder: any TempoTransferTxBuilder,
        broadcaster: (any TempoTransferBroadcaster)? = nil,
        clientId: String? = nil,
        defaultChainId: UInt64 = TempoChain.mainnet,
        approval: TempoApprovalPolicy = .allowAll,
        windowSeconds: UInt64 = TempoSettledChargeMethod.defaultWindowSeconds,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        guard let signer = try? Secp256k1Signer(privateKey: payerPrivateKey),
              let payer = EthereumAddress(uncompressedPublicKey: signer.publicKey)
        else { return nil }
        self.payerPrivateKey = payerPrivateKey
        self.payer = payer
        self.transferBuilder = transferBuilder
        self.broadcaster = broadcaster
        self.clientId = clientId
        self.defaultChainId = defaultChainId
        self.approval = approval
        self.windowSeconds = windowSeconds
        self.now = now
    }

    /// The payer address derived from the signing key, paid from and named in the `did:pkh` source.
    public var address: EthereumAddress {
        payer
    }

    /// The `Accept-Payment` ranges this method satisfies: the Tempo charge method/intent.
    public var paymentRanges: [PaymentRange] {
        [Self.chargeRange]
    }

    /// Whether this is a `tempo` / `charge` challenge with a decodable **non-zero** request that
    /// carries a valid-address `recipient` and `currency` and offers a mode this method can submit
    /// (pull always; push only when a broadcaster is configured).
    ///
    /// The addresses are parsed here (not merely checked for presence), so `supports` agrees with
    /// ``buildCredential(for:)`` -- which also requires them to parse -- and the flow never selects
    /// this method for a charge it would then reject (matching ``TempoChannelMethod``).
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == TempoMethod.name, challenge.intent == .charge,
              let request = try? TempoChargeRequest(challenge: challenge),
              !request.isZeroAmount,
              selectMode(request.supportedModes) != nil,
              let currency = request.currency, EthereumAddress(hex: currency) != nil,
              let recipient = request.recipient, EthereumAddress(hex: recipient) != nil
        else { return false }
        return true
    }

    /// The approval facts for `challenge`, filled from the decoded charge request.
    public func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest {
        guard let request = try? TempoChargeRequest(challenge: challenge) else {
            return PaymentApprovalRequest(generic: challenge)
        }
        return PaymentApprovalRequest(
            challengeId: challenge.id, realm: challenge.realm,
            method: challenge.method, intent: challenge.intent,
            amount: request.amount, currency: request.currency, recipient: request.recipient,
            description: challenge.description, expires: challenge.expires
        )
    }

    /// Builds the settled-charge credential for `challenge`, in pull or push mode.
    ///
    /// Decodes the charge, requires a non-zero amount with a `recipient` and `currency`, selects a
    /// submission mode the server allows (pull preferred; push when only push is offered and a
    /// broadcaster is configured), runs the approval gate (no signature is produced if it rejects),
    /// derives the attribution memo, and builds the transfer. In **pull** mode it returns the
    /// expiring-nonce transaction as the `{type: "transaction", signature}` credential the server
    /// broadcasts; in **push** mode it broadcasts a sequential-nonce transaction itself and returns
    /// the mined hash as the `{type: "hash", hash}` credential. Both carry the `did:pkh` source.
    ///
    /// - Throws: ``TempoSettledChargeError`` for a malformed/zero/under-specified request, no
    ///   acceptable mode, a rejected approval, a build failure, or a push-broadcast failure.
    public func buildCredential(for challenge: Challenge) async throws -> Credential {
        guard challenge.method == TempoMethod.name, challenge.intent == .charge else {
            throw TempoSettledChargeError.wrongMethodOrIntent
        }
        let request: TempoChargeRequest
        do {
            request = try TempoChargeRequest(challenge: challenge)
        } catch {
            throw TempoSettledChargeError.malformedRequest(error)
        }
        guard !request.isZeroAmount else { throw TempoSettledChargeError.zeroAmountCharge }
        guard let currencyHex = request.currency,
              let currency = EthereumAddress(hex: currencyHex)
        else { throw TempoSettledChargeError.missingOrInvalidCurrency }
        guard let recipientHex = request.recipient,
              let recipient = EthereumAddress(hex: recipientHex)
        else { throw TempoSettledChargeError.missingOrInvalidRecipient }
        guard let mode = selectMode(request.supportedModes) else {
            throw TempoSettledChargeError.unsupportedMode(request.supportedModes ?? [])
        }

        let chainId = request.chainId ?? defaultChainId
        let facts = ChargeApproval(
            challenge: challenge, chainId: chainId, amount: request.amount,
            currency: currencyHex, recipient: recipientHex
        )
        guard await approval.approves(facts) else { throw TempoSettledChargeError.approvalDenied }

        let memo = try resolveMemo(request, challenge: challenge)
        // Pull signs an expiring-nonce tx the server broadcasts; push signs a sequential-nonce tx
        // this client broadcasts (validBefore nil) and reports the mined hash.
        let parameters = TempoTransferParameters(
            payerPrivateKey: payerPrivateKey, payer: payer, currency: currency,
            recipient: recipient, amount: request.amount.rawValue, memo: memo,
            validBefore: mode == .pull ? validBefore(for: challenge.expires) : nil
        )
        let transaction: Data
        do {
            transaction = try await transferBuilder.buildTransferTransaction(
                parameters, chainID: chainId
            )
        } catch {
            throw TempoSettledChargeError.buildFailed(String(describing: error))
        }

        let payload = try await payload(for: mode, transaction: transaction)
        return Credential(
            challenge: challenge,
            source: ProofSource.did(address: payer, chainId: chainId),
            payload: payload
        )
    }

    /// The attribution memo: the server-pinned `methodDetails.memo` when present (a 32-byte
    /// `0x`-hex), otherwise a derived ``Attribution`` memo bound to the realm, client, and
    /// challenge.
    private func resolveMemo(
        _ request: TempoChargeRequest,
        challenge: Challenge
    ) throws -> Data {
        guard let memoHex = request.memo else {
            return Attribution.encode(
                serverId: challenge.realm, challengeId: challenge.id, clientId: clientId
            )
        }
        guard let memo = Data(hexPrefixed: memoHex), memo.count == 32 else {
            throw TempoSettledChargeError.invalidMemo
        }
        return memo
    }

    /// `validBefore` for the expiring-nonce tx: `now + window`, capped at the challenge's own
    /// expiry, in unix seconds. Mirrors the reference client.
    private func validBefore(for expires: Expires?) -> UInt64 {
        // `max(0, ...)` so a clock returning a pre-epoch date cannot trap the UInt64 conversion.
        let windowDeadline = UInt64(max(0, now().timeIntervalSince1970)) + windowSeconds
        guard let expires else { return windowDeadline }
        let challengeExpiry = UInt64(max(0, expires.date.timeIntervalSince1970))
        return min(windowDeadline, challengeExpiry)
    }

    /// Assembles the credential payload for the selected mode. Pull carries the signed transaction
    /// for the server to broadcast; push broadcasts it here and carries the mined hash.
    private func payload(
        for mode: Mode,
        transaction: Data
    ) async throws -> [String: JSONValue] {
        switch mode {
        case .pull:
            return ["type": .string("transaction"), "signature": .string(transaction.hexPrefixed)]
        case .push:
            // selectMode only returns .push when a broadcaster is present.
            guard let broadcaster else { throw TempoSettledChargeError.unsupportedMode(["push"]) }
            let hash: String
            do {
                hash = try await broadcaster.broadcast(transaction)
            } catch {
                throw TempoSettledChargeError.broadcastFailed(String(describing: error))
            }
            return ["type": .string("hash"), "hash": .string(hash)]
        }
    }

    /// Selects a submission mode the server allows: pull whenever it is acceptable (`nil`
    /// `supportedModes` means unconstrained), else push when push is offered and a broadcaster is
    /// configured. `nil` when neither can be satisfied (push-only without a broadcaster, or an
    /// empty
    /// `supportedModes`).
    private func selectMode(_ supportedModes: [String]?) -> Mode? {
        guard let supportedModes else { return .pull } // unconstrained -> prefer pull
        if supportedModes.contains("pull") { return .pull }
        if supportedModes.contains("push"), broadcaster != nil { return .push }
        return nil
    }

    /// The `tempo` / `charge` advertisement range, built once.
    private static let chargeRange: PaymentRange = {
        guard let range = try? PaymentRange(
            method: .value(TempoMethod.name), intent: .value(.charge)
        ) else {
            preconditionFailure("tempo/charge with default quality is a valid range")
        }
        return range
    }()
}

/// A reason ``TempoSettledChargeMethod`` could not build a credential.
public enum TempoSettledChargeError: Error, Sendable, Hashable {
    /// The challenge is not a Tempo charge (wrong `method` or `intent`).
    case wrongMethodOrIntent
    /// The challenge `request` could not be decoded.
    case malformedRequest(TempoChargeRequest.DecodingFailure)
    /// The charge is zero-amount; that is the proof path (``TempoProofMethod``), not a transfer.
    case zeroAmountCharge
    /// The settled transfer requires a `currency`, which was absent or not an address.
    case missingOrInvalidCurrency
    /// The settled transfer requires a `recipient`, which was absent or not an address.
    case missingOrInvalidRecipient
    /// The server's `supportedModes` offer no mode this method can submit (push-only without a
    /// configured broadcaster, or an empty list). Carries the offered modes.
    case unsupportedMode([String])
    /// The server pinned a `memo` that is not a 32-byte `0x`-hex value.
    case invalidMemo
    /// The pre-sign approval policy rejected the charge.
    case approvalDenied
    /// The transfer transaction could not be built; carries the underlying builder error's
    /// description (a `String`, so the type stays `Hashable` like its peers).
    case buildFailed(String)
    /// Push mode could not broadcast the transaction (or it reverted); carries the underlying
    /// broadcaster error's description.
    case broadcastFailed(String)
}

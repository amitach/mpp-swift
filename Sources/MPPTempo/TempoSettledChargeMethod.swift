import Foundation
import MPPClient
import MPPCore
import MPPEVM

/// The Tempo charge payment method, client side, for a **non-zero settled transfer** in **pull
/// mode** (the `transaction` credential).
///
/// It pays a `tempo` / `charge` challenge whose `amount` is non-zero by building a single
/// `currency.transferWithMemo(recipient, amount, memo)` `0x76` transaction, **payer-signed** as an
/// *expiring-nonce* transaction with `validBefore = min(now + window, challenge expiry)`, and
/// presenting it as the `{type: "transaction", signature: <raw tx hex>}` credential the `402`
/// server
/// broadcasts within the window (`draft-tempo-charge-00`). The zero-amount proof path is
/// ``TempoProofMethod``; push mode (the `hash` credential, where the client broadcasts) is a
/// separate method.
///
/// The transaction is built over an injected ``TempoTransferTxBuilder`` (the concrete FFI builder
/// holds the fee parameters), so this type only routes, gates, derives the attribution memo, and
/// assembles the ``Credential``. The payer address is derived from the signing key, so the
/// `did:pkh` source always matches it.
public struct TempoSettledChargeMethod: PaymentMethodClient {
    /// The default pull-mode validity window: the reference client signs a tx valid for ~25
    /// seconds.
    public static let defaultWindowSeconds: UInt64 = 25

    private let payerPrivateKey: Data
    private let payer: EthereumAddress
    private let transferBuilder: any TempoTransferTxBuilder
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
    /// carries a valid-address `recipient` and `currency` and is not constrained to push-only
    /// modes.
    ///
    /// The addresses are parsed here (not merely checked for presence), so `supports` agrees with
    /// ``buildCredential(for:)`` -- which also requires them to parse -- and the flow never selects
    /// this method for a charge it would then reject (matching ``TempoChannelMethod``).
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == TempoMethod.name, challenge.intent == .charge,
              let request = try? TempoChargeRequest(challenge: challenge),
              !request.isZeroAmount,
              let currency = request.currency, EthereumAddress(hex: currency) != nil,
              let recipient = request.recipient, EthereumAddress(hex: recipient) != nil
        else { return false }
        return Self.allowsPull(request.supportedModes)
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

    /// Builds the pull-mode `transaction` credential for `challenge`.
    ///
    /// Decodes the charge, requires a non-zero amount with a `recipient` and `currency`, checks
    /// pull
    /// mode is acceptable, runs the approval gate (no signature is produced if it rejects), derives
    /// the attribution memo, builds the expiring-nonce transfer, and assembles the credential with
    /// the `did:pkh` source and the `{type: "transaction", signature}` payload.
    ///
    /// - Throws: ``TempoSettledChargeError`` for a malformed/zero/under-specified request, an
    ///   unsupported mode, a rejected approval, or a build failure.
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
        guard Self.allowsPull(request.supportedModes) else {
            throw TempoSettledChargeError.pullModeUnsupported(request.supportedModes ?? [])
        }

        let chainId = request.chainId ?? defaultChainId
        let facts = ChargeApproval(
            challenge: challenge, chainId: chainId, amount: request.amount,
            currency: currencyHex, recipient: recipientHex
        )
        guard await approval.approves(facts) else { throw TempoSettledChargeError.approvalDenied }

        let memo = try resolveMemo(request, challenge: challenge)
        let parameters = TempoTransferParameters(
            payerPrivateKey: payerPrivateKey, payer: payer, currency: currency,
            recipient: recipient, amount: request.amount.rawValue, memo: memo,
            validBefore: validBefore(for: challenge.expires)
        )
        let transaction: Data
        do {
            transaction = try await transferBuilder.buildTransferTransaction(
                parameters, chainID: chainId
            )
        } catch {
            throw TempoSettledChargeError.buildFailed(String(describing: error))
        }

        let payload: [String: JSONValue] = [
            "type": .string("transaction"),
            "signature": .string(transaction.hexPrefixed),
        ]
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

    /// Whether the server's `supportedModes` allow pull (absent means unconstrained, both allowed).
    private static func allowsPull(_ supportedModes: [String]?) -> Bool {
        guard let supportedModes else { return true }
        return supportedModes.contains("pull")
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
    /// The server's `supportedModes` exclude pull, which is the only mode this method submits.
    case pullModeUnsupported([String])
    /// The server pinned a `memo` that is not a 32-byte `0x`-hex value.
    case invalidMemo
    /// The pre-sign approval policy rejected the charge.
    case approvalDenied
    /// The transfer transaction could not be built; carries the underlying builder error's
    /// description (a `String`, so the type stays `Hashable` like its peers).
    case buildFailed(String)
}

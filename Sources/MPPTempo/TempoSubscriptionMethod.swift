import Foundation
import MPPClient
import MPPCore
import MPPEVM

/// The client side of a Tempo subscription: a ``PaymentMethodClient`` that pays a `tempo` /
/// `subscription` challenge by signing a ``TempoKeyAuthorization``.
///
/// The root account (the `signer`) authorizes a server-held access key to make the recurring
/// `transferWithMemo(currency, recipient)` up to the per-period `limit` until the subscription
/// expires. The signed, RLP-serialized authorization is the credential's `signature`; the server
/// reconstructs the same authorization from the request to verify it. Construction derives the
/// payer
/// wallet from the signer's public key.
///
/// Activation is one-shot: this builds the credential a client presents once. Recurring renewals
/// are
/// server-driven (the server holds the access key) and are the subscription server's job, not this
/// method's.
public struct TempoSubscriptionMethod: PaymentMethodClient {
    private let signer: Secp256k1Signer
    private let wallet: EthereumAddress
    private let accessKey: SubscriptionRequest.AccessKey?
    private let defaultChainID: UInt64
    private let approval: TempoApprovalPolicy

    /// Creates the method over the root `signer`.
    ///
    /// - Parameters:
    ///   - signer: the root account's secp256k1 signer; its public key fixes the payer wallet and
    ///     signs the key authorization.
    ///   - accessKey: the access key to delegate to. When `nil`, the challenge's
    ///     `methodDetails.accessKey` is used; a credential cannot be built if neither is present.
    ///   - defaultChainID: the chain bound into the authorization when the challenge omits a chain
    /// id.
    ///   - approval: a pre-sign gate over the resolved charge facts; defaults to allow-all.
    /// - Returns: `nil` only if the signer's public key does not yield an address (which does not
    ///   happen for a signer built from a valid private key).
    public init?(
        signer: Secp256k1Signer,
        accessKey: SubscriptionRequest.AccessKey? = nil,
        defaultChainID: UInt64 = TempoChain.mainnet,
        approval: TempoApprovalPolicy = .allowAll
    ) {
        guard let wallet = EthereumAddress(uncompressedPublicKey: signer.publicKey) else {
            return nil
        }
        self.signer = signer
        self.wallet = wallet
        self.accessKey = accessKey
        self.defaultChainID = defaultChainID
        self.approval = approval
    }

    /// The payer (root) address derived from the signer, named in the credential's `did:pkh`
    /// source.
    public var address: EthereumAddress {
        wallet
    }

    /// The `Accept-Payment` range this method satisfies: the Tempo subscription method/intent.
    public var paymentRanges: [PaymentRange] {
        [Self.subscriptionRange]
    }

    /// Whether this is a `tempo` / `subscription` challenge with a decodable request.
    public func supports(_ challenge: Challenge) -> Bool {
        SubscriptionRequest.supports(challenge)
    }

    /// The approval facts for `challenge`, filling amount/currency/recipient from the
    /// decoded subscription request (the same fields the per-method ``ChargeApproval`` carries).
    /// An undecodable request falls back to the rail-agnostic facts.
    public func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest {
        guard let request = try? SubscriptionRequest(challenge: challenge) else {
            return PaymentApprovalRequest(generic: challenge)
        }
        return PaymentApprovalRequest(
            challengeId: challenge.id, realm: challenge.realm,
            method: challenge.method, intent: challenge.intent,
            amount: request.amount, currency: request.currency.checksummed,
            recipient: request.recipient.checksummed,
            description: challenge.description, expires: challenge.expires
        )
    }

    /// Builds the key-authorization credential for `challenge`.
    ///
    /// - Throws: ``TempoSubscriptionMethodError`` for a wrong method/intent, a malformed request,
    /// an
    ///   absent access key, a rejected approval, or a signing failure.
    public func buildCredential(for challenge: Challenge) async throws -> Credential {
        // Authoritative re-check (the flow filters with supports() first, but this is public).
        guard challenge.method == TempoMethod.name, challenge.intent == .subscription else {
            throw TempoSubscriptionMethodError.wrongMethodOrIntent
        }
        let request: SubscriptionRequest
        do {
            request = try SubscriptionRequest(challenge: challenge)
        } catch {
            throw TempoSubscriptionMethodError.malformedRequest(error)
        }
        let chainID = request.chainId ?? defaultChainID
        guard let key = accessKey ?? request.accessKey else {
            throw TempoSubscriptionMethodError.noAccessKey
        }

        // The pre-sign gate sees the resolved charge facts (the existing approval surface; the
        // recurring period/expiry are not part of it).
        let facts = ChargeApproval(
            challenge: challenge,
            chainId: chainID,
            amount: request.amount,
            currency: request.currency.checksummed,
            recipient: request.recipient.checksummed
        )
        guard await approval.approves(facts) else {
            throw TempoSubscriptionMethodError.approvalDenied
        }

        let authorization = request.keyAuthorization(accessKey: key, chainId: chainID)
        let serialized: Data
        do {
            serialized = try authorization.signedSerialization(with: signer)
        } catch {
            throw TempoSubscriptionMethodError.signingFailed(error)
        }
        return Credential(
            challenge: challenge,
            source: ProofSource.did(address: wallet, chainId: chainID),
            payload: [
                "type": .string("keyAuthorization"),
                "signature": .string(serialized.hexPrefixed),
            ]
        )
    }

    /// The `tempo` / `subscription` advertisement range, built once (the default quality is in
    /// range, so this cannot fail).
    private static let subscriptionRange: PaymentRange = {
        guard let range = try? PaymentRange(
            method: .value(TempoMethod.name), intent: .value(.subscription)
        ) else {
            preconditionFailure("tempo/subscription with default quality is a valid range")
        }
        return range
    }()
}

/// A reason ``TempoSubscriptionMethod`` could not build a credential.
public enum TempoSubscriptionMethodError: Error, Sendable, Hashable {
    /// The challenge is not a Tempo subscription (wrong `method` or `intent`).
    case wrongMethodOrIntent
    /// The challenge `request` could not be decoded.
    case malformedRequest(SubscriptionRequest.DecodingFailure)
    /// No access key was configured on the method or carried by the challenge.
    case noAccessKey
    /// The pre-sign approval policy rejected the subscription.
    case approvalDenied
    /// The key authorization could not be signed/serialized.
    case signingFailed(TempoKeyAuthorization.AuthorizationError)
}

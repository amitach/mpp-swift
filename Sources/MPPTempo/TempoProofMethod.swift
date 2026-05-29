import Foundation
import MPPClient
import MPPCore
import MPPEVM

/// The Tempo charge payment method, client side, for the zero-amount EIP-712
/// proof path only.
///
/// It pays a `tempo` / `charge` challenge whose `amount` is `0` by signing an
/// EIP-712 proof of wallet control (no on-chain settlement). A non-zero charge
/// is a settled transfer that requires the Tempo `0x76` transaction layer and is
/// reported unsupported here (a later PR). Signing reuses ``ZeroAmountProof`` and
/// ``Secp256k1Signer`` from `MPPEVM`; this type only routes and assembles the
/// ``Credential``.
///
/// Construction derives the wallet address from the signer's public key, so the
/// `did:pkh` source and the v1 `wallet` field always match the signing key.
public struct TempoProofMethod: PaymentMethodClient {
    private let signer: Secp256k1Signer
    private let wallet: EthereumAddress
    private let defaultChainId: UInt64?
    private let variant: ProofVariant
    private let approval: TempoApprovalPolicy

    /// Creates the method over a signer.
    ///
    /// - Parameters:
    ///   - signer: The secp256k1 signer; its public key fixes the wallet address.
    ///   - defaultChainId: The chain to bind the proof to when the challenge's
    ///     `methodDetails.chainId` is absent. With neither, building fails closed.
    ///   - variant: Which proof shape to emit (defaults to ``ProofVariant/v2Realm``).
    ///   - approval: The pre-sign spending control (defaults to
    ///     ``TempoApprovalPolicy/allowAll``).
    /// - Returns: `nil` only if a valid Ethereum address cannot be derived from
    ///   the signer's public key (which does not happen for a signer built from a
    ///   valid private key).
    public init?(
        signer: Secp256k1Signer,
        defaultChainId: UInt64? = nil,
        variant: ProofVariant = .v2Realm,
        approval: TempoApprovalPolicy = .allowAll
    ) {
        guard let wallet = EthereumAddress(uncompressedPublicKey: signer.publicKey) else {
            return nil
        }
        self.signer = signer
        self.wallet = wallet
        self.defaultChainId = defaultChainId
        self.variant = variant
        self.approval = approval
    }

    /// The Ethereum address derived from the signer, paid from and named in the
    /// `did:pkh` source.
    public var address: EthereumAddress {
        wallet
    }

    /// The `Accept-Payment` ranges this method can satisfy: the Tempo charge
    /// method/intent. A client builds its `Accept-Payment` header from the union
    /// of its methods' ranges (`AcceptPayment.format(...)`) rather than hardcoding
    /// the value, so advertising stays derived from the registered methods.
    public var paymentRanges: [PaymentRange] {
        // Fixed, grammar-valid tokens, so this construction never fails.
        guard let range = try? PaymentRange(
            method: .value(Self.tempoMethod),
            intent: .value(Self.chargeIntent)
        ) else {
            return []
        }
        return [range]
    }

    /// Whether this is a `tempo` / `charge` challenge with a decodable
    /// zero-amount request whose chain is resolvable.
    ///
    /// A decode failure means the challenge is not one this method can pay, so it
    /// is mapped to `false` here (the throwing decode is re-run in
    /// ``buildCredential(for:)``, which surfaces the specific reason). A non-zero
    /// amount is a settled transfer this PR does not handle.
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == Self.tempoMethod, challenge.intent == Self.chargeIntent,
              let request = try? TempoChargeRequest(challenge: challenge),
              request.isZeroAmount
        else { return false }
        return (request.chainId ?? defaultChainId) != nil
    }

    /// Builds the zero-amount proof credential for `challenge`.
    ///
    /// Decodes the charge, runs the approval gate (no signature is produced if it
    /// rejects), signs the EIP-712 proof for the selected variant, and assembles
    /// the credential with the `did:pkh` source and the `{type, signature}`
    /// payload.
    ///
    /// - Throws: ``TempoMethodError`` for a malformed request, a non-zero amount,
    ///   an unresolvable chain, a rejected approval, or a signing failure.
    public func buildCredential(for challenge: Challenge) async throws -> Credential {
        // Authoritative re-check (the flow filters with supports() first, but this
        // method is public): the proof binds only (challengeId, realm), not the
        // method/intent, so never sign one for a challenge that is not a Tempo
        // charge, even if called directly.
        guard challenge.method == Self.tempoMethod, challenge.intent == Self.chargeIntent else {
            throw TempoMethodError.wrongMethodOrIntent
        }
        let request: TempoChargeRequest
        do {
            request = try TempoChargeRequest(challenge: challenge)
        } catch {
            throw TempoMethodError.malformedRequest(error)
        }
        guard request.isZeroAmount else { throw TempoMethodError.notAZeroAmountCharge }
        guard let chainId = request.chainId ?? defaultChainId else {
            throw TempoMethodError.missingChainId
        }

        let facts = ChargeApproval(
            realm: challenge.realm,
            amount: request.amount,
            currency: request.currency,
            recipient: request.recipient,
            validUntil: challenge.expires
        )
        guard await approval.approves(facts) else { throw TempoMethodError.approvalDenied }

        let proof: ZeroAmountProof = switch variant {
        case .v2Realm: .v2Realm(challengeId: challenge.id, realm: challenge.realm)
        case .v1Wallet: .v1Wallet(challengeId: challenge.id, wallet: wallet)
        }
        let signature: Data
        do {
            signature = try proof.sign(chainId: chainId, with: signer)
        } catch {
            throw TempoMethodError.signingFailed(error)
        }

        let payload: [String: JSONValue] = [
            "type": .string("proof"),
            "signature": .string(Self.hexPrefixed(signature)),
        ]
        return Credential(
            challenge: challenge,
            source: ProofSource.did(address: wallet, chainId: chainId),
            payload: payload
        )
    }

    /// `0x`-prefixed lowercase hex, the form an Ethereum signature travels in.
    private static func hexPrefixed(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    /// The canonical `tempo` method name. Fixed and grammar-valid by construction.
    private static let tempoMethod: MethodName = {
        guard let name = try? MethodName("tempo") else {
            preconditionFailure("tempo is a valid method name")
        }
        return name
    }()

    /// The canonical `charge` intent. Fixed and grammar-valid by construction.
    private static let chargeIntent: IntentName = {
        guard let intent = try? IntentName("charge") else {
            preconditionFailure("charge is a valid intent name")
        }
        return intent
    }()
}

/// A reason ``TempoProofMethod`` could not build a credential.
public enum TempoMethodError: Error, Sendable, Hashable {
    /// The challenge is not a Tempo charge (wrong `method` or `intent`).
    case wrongMethodOrIntent
    /// The challenge `request` could not be decoded.
    case malformedRequest(TempoChargeRequest.DecodingFailure)
    /// The charge is not zero-amount; a settled transfer needs the transaction
    /// layer, which this method does not implement.
    case notAZeroAmountCharge
    /// No chain id in the challenge and none configured on the method.
    case missingChainId
    /// The pre-sign approval policy rejected the charge.
    case approvalDenied
    /// The EIP-712 proof could not be signed.
    case signingFailed(Secp256k1Signer.SigningError)
}

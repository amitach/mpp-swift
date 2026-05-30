import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo

/// The server-side Tempo charge method, for the zero-amount EIP-712 proof path:
/// the verify counterpart to ``TempoProofMethod``.
///
/// It settles a `tempo` / `charge` challenge whose `amount` is `0` by recovering
/// the EIP-712 proof signature in the credential and checking it against the
/// payer's `did:pkh` source wallet. Recovery reuses ``ZeroAmountProof`` and
/// ``EthereumAddress`` from `MPPEVM`; this type routes, decodes the payload, and
/// applies the acceptance check.
///
/// Because a credential carries no marker of which proof variant produced it, the
/// verifier accepts any configured variant whose signature recovers to the source
/// wallet (default: all three). That is safe: the `challengeId` is unforgeable
/// (the server's challenge-id HMAC) and the source address is pinned, so the
/// proof's own `realm`/`wallet` binding is belt-and-suspenders.
///
/// - Important: this proves only **control of the wallet named in the credential's
///   `source`** (which is self-asserted by the payer), for the bound challenge. It
///   does NOT establish that that wallet is funded, allow-listed, or otherwise
///   authorized to access the resource. A caller that gates on identity must
///   authorize the verified `source` wallet out of band; "verified" here means
///   "the bearer controls this wallet," not "this payer is entitled."
public struct TempoProofVerifier: PaymentMethodServer {
    private let defaultChainId: UInt64
    private let acceptedVariants: [ProofVariant]

    /// Creates the verifier.
    ///
    /// - Parameters:
    ///   - defaultChainId: The chain to verify against when the challenge omits
    ///     `methodDetails.chainId` (defaults to ``TempoChain/mainnet``, matching
    ///     the client and the reference SDKs).
    ///   - acceptedVariants: The proof shapes to accept (defaults to all three:
    ///     v2 realm, v1 wallet, and the spec single-field form).
    public init(
        defaultChainId: UInt64 = TempoChain.mainnet,
        acceptedVariants: [ProofVariant] = [.v2Realm, .v1Wallet, .specChallengeId]
    ) {
        // An empty set would reject every proof with `.signatureMismatch`; that is a
        // configuration error, so fail fast rather than silently reject everything.
        precondition(!acceptedVariants.isEmpty, "acceptedVariants must not be empty")
        self.defaultChainId = defaultChainId
        self.acceptedVariants = acceptedVariants
    }

    /// Whether this is a `tempo` / `charge` challenge with a decodable zero-amount
    /// request (the proof path).
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == TempoMethod.name, challenge.intent == .charge,
              let request = try? TempoChargeRequest(challenge: challenge)
        else { return false }
        return request.isZeroAmount
    }

    /// Verifies the zero-amount proof carried by `credential` and mints its receipt.
    ///
    /// - Returns: A ``Receipt`` whose `reference` is the challenge id: a zero-amount
    ///   proof settles no value on-chain, so it references the challenge it
    ///   satisfied rather than a transaction hash, with no method-specific extras.
    /// - Throws: ``VerifyError`` if the request is malformed or not zero-amount,
    ///   the payload is not a `proof`, the `source` is missing or its chain does
    ///   not match, the signature is malformed, or the signature does not recover
    ///   to the source wallet under any accepted variant.
    public func verify(_ credential: Credential, now: Date) async throws(VerifyError) -> Receipt {
        let challenge = credential.challenge
        let request: TempoChargeRequest
        do {
            request = try TempoChargeRequest(challenge: challenge)
        } catch {
            throw .malformedRequest(error)
        }
        guard request.isZeroAmount else { throw .notAZeroAmountCharge }
        let chainId = request.chainId ?? defaultChainId

        guard credential.payload["type"]?.stringValue == "proof" else { throw .notAProof }
        guard let signatureHex = credential.payload["signature"]?.stringValue else {
            throw .missingSignature
        }
        guard let source = credential.source, let parsed = ProofSource.parse(source) else {
            throw .invalidSource
        }
        guard parsed.chainId == chainId else { throw .chainIdMismatch }
        guard let signature = Data(hexPrefixed: signatureHex), signature.count == 65 else {
            throw .malformedSignature
        }
        guard recovers(
            challenge: challenge, chainId: chainId, signature: signature, to: parsed.address
        ) else {
            throw .signatureMismatch
        }
        return Receipt(
            method: challenge.method, timestamp: RFC3339DateTime(date: now), reference: challenge.id
        )
    }

    /// Whether `signature` recovers to `wallet` under any accepted proof variant.
    private func recovers(
        challenge: Challenge, chainId: UInt64, signature: Data, to wallet: EthereumAddress
    ) -> Bool {
        for variant in acceptedVariants {
            let proof: ZeroAmountProof = switch variant {
            case .v2Realm: .v2Realm(challengeId: challenge.id, realm: challenge.realm)
            case .v1Wallet: .v1Wallet(challengeId: challenge.id, wallet: wallet)
            case .specChallengeId: .v1ChallengeId(challengeId: challenge.id)
            }
            if proof.recoverSigner(chainId: chainId, signature: signature) == wallet {
                return true
            }
        }
        return false
    }

    /// A reason ``TempoProofVerifier`` rejected a credential.
    public enum VerifyError: Error, Sendable, Hashable {
        /// The challenge `request` could not be decoded.
        case malformedRequest(TempoChargeRequest.DecodingFailure)
        /// The charge is not zero-amount; this verifier only settles proofs.
        case notAZeroAmountCharge
        /// The credential payload was not a `proof` (missing or wrong `type`).
        case notAProof
        /// The proof payload had no `signature`.
        case missingSignature
        /// The credential had no `source`, or it was not a valid `did:pkh:eip155` DID.
        case invalidSource
        /// The `source` chain did not match the challenge's chain.
        case chainIdMismatch
        /// The signature was not 65 bytes of `0x`-prefixed hex.
        case malformedSignature
        /// The signature did not recover to the source wallet under any accepted variant.
        case signatureMismatch
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

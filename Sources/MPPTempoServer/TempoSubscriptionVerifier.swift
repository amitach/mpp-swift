import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPTempo

/// The server-side Tempo subscription method: the verify counterpart to
/// ``TempoSubscriptionMethod``, settling the one-shot activation of a
/// `tempo` / `subscription` challenge.
///
/// It accepts a credential carrying a signed ``TempoKeyAuthorization`` by
/// **re-encode-and-compare**: it reconstructs the authorization it expects purely
/// from its own challenge `request` (the access key, currency, recipient, amount,
/// period, expiry, and chain it issued), then requires the credential's
/// authorization to equal that expected one byte-for-byte. The client decode is
/// never trusted: a non-canonical encoding fails the strict RLP decode, and any
/// field the client changed (a wider limit, a different recipient or access key, a
/// later expiry) makes the authorization mismatch and rejects. It then recovers
/// the payer from the signature and pins it to the credential's `did:pkh` source.
///
/// Activation is one-shot, so ``reusesChallenge`` stays `false`: the verifier
/// consumes the challenge id once. Recurring renewals are server-driven (the
/// server holds the access key it authorized) and belong to the subscription
/// store / renewal engine, not to re-presenting this challenge.
///
/// - Important: a verified credential proves the payer **signed an authorization
///   delegating the issued access key** for this subscription, bound to the
///   challenge. It does not itself move funds; the recurring `transferWithMemo`
///   the authorization permits is settled later by the renewal engine, within the
///   per-period `limit` the authorization fixes.
public struct TempoSubscriptionVerifier: PaymentMethodServer {
    private let defaultChainID: UInt64

    /// Creates the verifier.
    ///
    /// - Parameter defaultChainID: the chain to verify against when the challenge
    ///   omits `methodDetails.chainId` (defaults to ``TempoChain/mainnet``, matching
    ///   the client).
    public init(defaultChainID: UInt64 = TempoChain.mainnet) {
        self.defaultChainID = defaultChainID
    }

    /// Whether this is a `tempo` / `subscription` challenge with a decodable request.
    public func supports(_ challenge: Challenge) -> Bool {
        SubscriptionRequest.supports(challenge)
    }

    /// Verifies the signed key authorization carried by `credential` and mints its
    /// activation receipt.
    ///
    /// - Returns: a ``Receipt`` whose `reference` is the challenge id: activation
    ///   settles no value on-chain (the recurring transfers do, later), so it
    ///   references the subscription challenge it satisfied.
    /// - Throws: ``VerifyError`` if the request is malformed, the challenge carries
    ///   no access key to rebuild against, the payload is not a `keyAuthorization`,
    ///   the `source` is missing or its chain does not match, the serialization is
    ///   malformed, the embedded authorization does not equal the one the request
    ///   reconstructs, the expiry is not strictly after the challenge deadline, or
    ///   the signature does not recover to the source wallet.
    public func verify(_ credential: Credential, now: Date) async throws(VerifyError) -> Receipt {
        _ = try verified(credential, now: now)
        let challenge = credential.challenge
        return Receipt(
            method: challenge.method, timestamp: RFC3339DateTime(date: now), reference: challenge.id
        )
    }

    /// Verifies the signed key authorization carried by `credential` and returns the
    /// activation it proves: the decoded ``SubscriptionRequest``, the recovered
    /// `payer`, the serialized authorization bytes, and the bound chain.
    ///
    /// This is the verification ``verify(_:now:)`` performs, exposed so a server can
    /// persist the activation (build a ``SubscriptionRecord`` and store it for renewal)
    /// from the same checks rather than re-deriving them. ``verify(_:now:)`` calls this
    /// and maps the result to its ``Receipt``, so the two share one verification path.
    ///
    /// - Throws: the same ``VerifyError`` cases, in the same order, as ``verify(_:now:)``.
    public func verified(_ credential: Credential, now: Date) throws(VerifyError) -> Verified {
        let challenge = credential.challenge
        let request: SubscriptionRequest
        do {
            request = try SubscriptionRequest(challenge: challenge)
        } catch {
            throw .malformedRequest(error)
        }
        let chainID = request.chainId ?? defaultChainID
        // The verifier rebuilds against the access key IT issued in the challenge;
        // a subscription the server cannot reconstruct cannot be verified.
        guard let accessKey = request.accessKey else { throw .noAccessKey }

        let presented = try Self.presentedAuthorization(credential, chainID: chainID)
        let serialized = presented.serialized
        let sourceWallet = presented.sourceWallet

        // The key authorization the server expects, derived only from its own
        // request: the single source of truth shared with the client.
        let expected = request.keyAuthorization(accessKey: accessKey, chainId: chainID)
        let decoded: TempoKeyAuthorization
        let payer: EthereumAddress
        do {
            decoded = try TempoKeyAuthorization.deserialize(serialized).authorization
            payer = try TempoKeyAuthorization.recover(serialized: serialized)
        } catch {
            // A malformed, non-canonical, or unsigned serialization.
            throw .malformedSerialization
        }
        // Re-encode-and-compare: the strict RLP decode rejects non-canonical bytes,
        // and a canonical encoding is unique, so equality of the decoded authorization
        // to the expected one is byte-equality of the signed inner tuple.
        guard decoded == expected else { throw .authorizationMismatch }
        // The authorization must outlive the challenge it activates.
        let deadline = challenge.expires?.date.timeIntervalSince1970 ?? now.timeIntervalSince1970
        guard Double(request.expirySeconds) > deadline else { throw .expiryNotAfterChallenge }
        // The signer of the authorization must be the wallet the credential claims.
        guard payer == sourceWallet else { throw .signatureMismatch }

        return Verified(
            request: request, payer: payer, serializedAuthorization: serialized, chainID: chainID
        )
    }

    /// A verified subscription activation: everything a server needs to persist a
    /// ``SubscriptionRecord`` for renewal, proven from one credential.
    public struct Verified: Sendable, Hashable {
        /// The decoded, fully validated subscription terms from the challenge.
        public let request: SubscriptionRequest
        /// The payer (root) wallet recovered from the authorization signature; equal
        /// to the credential's `did:pkh` source.
        public let payer: EthereumAddress
        /// The serialized signed ``TempoKeyAuthorization`` the renewal engine replays.
        public let serializedAuthorization: Data
        /// The chain the authorization is bound to (the request's, or the verifier's
        /// default when the challenge omits it).
        public let chainID: UInt64

        public init(
            request: SubscriptionRequest,
            payer: EthereumAddress,
            serializedAuthorization: Data,
            chainID: UInt64
        ) {
            self.request = request
            self.payer = payer
            self.serializedAuthorization = serializedAuthorization
            self.chainID = chainID
        }
    }

    /// The serialized authorization and the source wallet a credential presents,
    /// after the payload-shape and `did:pkh` checks (extracted so ``verify`` stays
    /// within the cyclomatic-complexity budget).
    private static func presentedAuthorization(
        _ credential: Credential, chainID: UInt64
    ) throws(VerifyError) -> (serialized: Data, sourceWallet: EthereumAddress) {
        guard credential.payload["type"]?.stringValue == "keyAuthorization" else {
            throw .notAKeyAuthorization
        }
        guard let serializedHex = credential.payload["signature"]?.stringValue else {
            throw .missingSerialization
        }
        guard let source = credential.source, let parsed = ProofSource.parse(source) else {
            throw .invalidSource
        }
        guard parsed.chainId == chainID else { throw .chainIdMismatch }
        guard let serialized = Data(hexPrefixed: serializedHex) else {
            throw .malformedSerialization
        }
        return (serialized, parsed.address)
    }

    /// A reason ``TempoSubscriptionVerifier`` rejected a credential.
    public enum VerifyError: Error, Sendable, Hashable {
        /// The challenge `request` could not be decoded.
        case malformedRequest(SubscriptionRequest.DecodingFailure)
        /// The challenge carried no access key, so the authorization cannot be rebuilt.
        case noAccessKey
        /// The credential payload was not a `keyAuthorization` (missing or wrong `type`).
        case notAKeyAuthorization
        /// The payload had no serialized authorization `signature`.
        case missingSerialization
        /// The credential had no `source`, or it was not a valid `did:pkh:eip155` DID.
        case invalidSource
        /// The `source` chain did not match the challenge's chain.
        case chainIdMismatch
        /// The serialization was not a canonical signed key authorization.
        case malformedSerialization
        /// The embedded authorization did not equal the one the request reconstructs.
        case authorizationMismatch
        /// The authorization expiry was not strictly after the challenge deadline.
        case expiryNotAfterChallenge
        /// The signature did not recover to the source wallet.
        case signatureMismatch
    }
}

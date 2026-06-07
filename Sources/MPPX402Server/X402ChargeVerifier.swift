import Foundation
import MPPCore
import MPPEVM
import MPPServer
import MPPX402

/// The on-chain settlement the verifier needs: submit a signed EIP-3009 `transferWithAuthorization`
/// and return its settled transaction hash. A seam so the verifier stays free of a concrete
/// transport -- an RPC relayer that builds the transaction, or an x402 facilitator that settles on
/// the server's behalf; tests inject a stub. The live implementation lands with the bridge / e2e.
public protocol X402Settlement: Sendable {
    /// Submits `authorization` (signed by `signature` under `domain`) on-chain and returns the
    /// settled `0x`-prefixed transaction hash. Throws if it cannot settle (a revert, a relay
    /// failure, an already-used nonce).
    func settle(
        authorization: X402Authorization, domain: X402Domain, signature: Data
    ) async throws -> String
}

/// The server-side x402 charge method: verifies a signed EIP-3009 authorization against the
/// challenge and settles it on-chain (`draft` x402 exact scheme, adapted to the MPP rail).
///
/// It confirms the credential's exact-scheme payload:
/// - the signature recovers to the authorization's `from` under the advertised token domain (EIP-2
///   low-`s`, matching the token contract), and that `from` is the credential's `did:pkh` source;
/// - the authorization's **recipient, value, token, and chain** match the challenge, and `now` is
///   inside `[validAfter, validBefore)`;
///
/// then **single-uses the authorization** (its signing hash, unique per authorization+domain) via
/// the ``ReplayStore`` and **settles** it through the injected ``X402Settlement``. The on-chain
/// `transferWithAuthorization` is itself nonce-single-use, so the store is a fast off-chain guard
/// against a redundant (gas-wasting) second submit, not the only one -- a double-spend is
/// impossible
/// regardless, because the token rejects a reused nonce.
///
/// - Important: this proves an authorization **settled on-chain for this challenge**; a caller
///   gating on identity must still authorize the payer out of band.
public struct X402ChargeVerifier: PaymentMethodServer {
    private let settlement: any X402Settlement
    private let replayStore: any ReplayStore
    private let defaultChainId: UInt64

    /// Creates the verifier.
    /// - Parameters:
    ///   - settlement: submits the authorization on-chain (a relayer or facilitator).
    ///   - replayStore: enforces single-use of a settled authorization.
    ///   - defaultChainId: the chain to verify against when the challenge omits
    ///     `methodDetails.chainId` (defaults to Base mainnet).
    public init(
        settlement: any X402Settlement,
        replayStore: any ReplayStore,
        defaultChainId: UInt64 = X402Chain.baseMainnet
    ) {
        self.settlement = settlement
        self.replayStore = replayStore
        self.defaultChainId = defaultChainId
    }

    /// Whether this is an `exact` (x402) / `charge` challenge with a decodable **non-zero**
    /// request.
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == X402Method.name, challenge.intent == .charge,
              let request = try? X402ChargeRequest(challenge: challenge),
              request.amount.rawValue != "0"
        else { return false }
        return true
    }

    /// Verifies the x402 charge carried by `credential` and mints its receipt (whose `reference` is
    /// the settled transaction hash).
    public func verify(_ credential: Credential, now: Date) async throws(VerifyError) -> Receipt {
        let terms = try chargeTerms(credential.challenge)
        guard let source = credential.source, let parsed = ProofSource.parse(source) else {
            throw .invalidSource
        }
        guard parsed.chainId == terms.chainId else { throw .chainIdMismatch }
        let (authorization, signature) = try exactPayload(credential.payload)
        let domain = X402Domain(
            name: terms.name, version: terms.version, chainId: terms.chainId, asset: terms.currency
        )
        try validate(Decoded(
            authorization: authorization, signature: signature, domain: domain,
            terms: terms, source: parsed.address
        ), now: now)

        // Single-use: the signing hash uniquely identifies (authorization, domain). First wins; the
        // on-chain nonce is the ultimate guard, so this only avoids a redundant submit.
        guard await replayStore.consume(authorization.signingHash(domain: domain).hexPrefixed)
        else {
            throw .alreadySettled
        }
        let txHash: String
        do {
            txHash = try await settlement.settle(
                authorization: authorization, domain: domain, signature: signature
            )
        } catch {
            throw .settlementFailed(String(describing: error))
        }
        return Receipt(
            method: credential.challenge.method, timestamp: RFC3339DateTime(date: now),
            reference: txHash
        )
    }

    /// The challenge's settlement terms (the parsed addresses, token domain inputs, amount, chain).
    private struct ChargeTerms {
        let recipient: EthereumAddress
        let currency: EthereumAddress
        let name: String
        let version: String
        let amount: Amount
        let chainId: UInt64
    }

    /// The decoded, not-yet-validated charge: the signed authorization plus everything it must be
    /// checked against.
    private struct Decoded {
        let authorization: X402Authorization
        let signature: Data
        let domain: X402Domain
        let terms: ChargeTerms
        let source: EthereumAddress
    }

    /// Decodes and address-validates the challenge's settlement terms.
    private func chargeTerms(_ challenge: Challenge) throws(VerifyError) -> ChargeTerms {
        let request: X402ChargeRequest
        do {
            request = try X402ChargeRequest(challenge: challenge)
        } catch {
            throw .malformedRequest(error)
        }
        guard request.amount.rawValue != "0" else { throw .notACharge }
        guard let currencyHex = request.currency, let currency = EthereumAddress(hex: currencyHex)
        else { throw .missingOrInvalidCurrency }
        guard let recipientHex = request.recipient,
              let recipient = EthereumAddress(hex: recipientHex)
        else { throw .missingOrInvalidRecipient }
        guard let name = request.tokenName, let version = request.tokenVersion else {
            throw .missingTokenDomain
        }
        return ChargeTerms(
            recipient: recipient, currency: currency, name: name, version: version,
            amount: request.amount, chainId: request.chainId ?? defaultChainId
        )
    }

    /// Decodes the exact-scheme payload from the credential into its authorization and signature.
    private func exactPayload(
        _ payload: [String: JSONValue]
    ) throws(VerifyError) -> (X402Authorization, Data) {
        guard let exact = X402ExactPayload(credentialPayload: payload)
        else { throw .malformedPayload }
        guard let authorization = exact.authorization.decoded()
        else { throw .malformedAuthorization }
        guard let signature = exact.signatureBytes else { throw .malformedSignature }
        return (authorization, signature)
    }

    /// Confirms the signature recovers to `from` (EIP-2 low-`s`), `from` is the `did:pkh` source,
    /// and the authorization's recipient / value / window match the challenge.
    private func validate(_ decoded: Decoded, now: Date) throws(VerifyError) {
        let auth = decoded.authorization
        guard auth.isSignedByFrom(
            domain: decoded.domain, signature: decoded.signature, malleability: .rejectHighS
        ) else {
            throw .signatureMismatch
        }
        guard auth.from == decoded.source else { throw .sourceMismatch }
        guard auth.recipient == decoded.terms.recipient else { throw .recipientMismatch }
        guard auth.value == decoded.terms.amount else { throw .amountMismatch }
        let nowSeconds = UInt64(max(0, now.timeIntervalSince1970))
        guard nowSeconds >= auth.validAfter, nowSeconds < auth.validBefore else {
            throw .outsideValidityWindow
        }
    }

    /// A reason ``X402ChargeVerifier`` rejected a credential.
    public enum VerifyError: Error, Sendable, Hashable {
        /// The challenge `request` could not be decoded.
        case malformedRequest(X402ChargeRequest.DecodingFailure)
        /// The charge was zero-amount; x402 settles a non-zero transfer.
        case notACharge
        /// The request had no `currency` (token), or it was not an address.
        case missingOrInvalidCurrency
        /// The request had no `recipient`, or it was not an address.
        case missingOrInvalidRecipient
        /// The request did not carry the token's EIP-712 domain (`name` + `version`).
        case missingTokenDomain
        /// The credential had no `source`, or it was not a valid `did:pkh:eip155` DID.
        case invalidSource
        /// The `source` chain did not match the challenge's chain.
        case chainIdMismatch
        /// The credential payload was not an x402 exact payload.
        case malformedPayload
        /// The payload's `authorization` could not be parsed.
        case malformedAuthorization
        /// The payload's `signature` was not 65-byte `0x`-hex.
        case malformedSignature
        /// The signature did not recover to the authorization's `from` (or was non-canonical
        /// high-`s`).
        case signatureMismatch
        /// The authorization's `from` did not equal the credential's `did:pkh` source.
        case sourceMismatch
        /// The authorization's recipient did not match the challenge.
        case recipientMismatch
        /// The authorization's value did not match the challenge amount.
        case amountMismatch
        /// `now` was outside the authorization's `[validAfter, validBefore)` window.
        case outsideValidityWindow
        /// The authorization was already used to settle a charge (single-use).
        case alreadySettled
        /// Settlement failed (a revert, relay failure, or already-used on-chain nonce); carries the
        /// underlying cause.
        case settlementFailed(String)
    }
}

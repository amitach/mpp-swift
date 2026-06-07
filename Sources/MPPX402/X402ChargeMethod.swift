import Foundation
import MPPClient
import MPPCore
import MPPEVM

/// The x402 charge payment method, client side: pays an `x402` / `charge` challenge by signing an
/// EIP-3009 `transferWithAuthorization` over the advertised token (USDC on Base) and presenting it
/// as the credential. Gasless for the payer -- a facilitator / relayer (or this SDK's server
/// verifier) submits the authorization on-chain.
///
/// It decodes the charge (``X402ChargeRequest``), builds an ``X402Authorization`` from the payer
/// (a random `bytes32` nonce, `validBefore = now + maxTimeoutSeconds`), signs it under the token's
/// EIP-712 domain (`name` / `version` / `chainId` / `asset`, all from the challenge), and assembles
/// the ``Credential`` carrying the exact-scheme `payload` plus a `did:pkh` source naming the payer.
public struct X402ChargeMethod: PaymentMethodClient {
    /// The default authorization window when the challenge omits `maxTimeoutSeconds`.
    public static let defaultTimeoutSeconds: UInt64 = 300

    private let signer: Secp256k1Signer
    private let payer: EthereumAddress
    private let defaultChainId: UInt64
    private let approval: X402ApprovalPolicy
    private let now: @Sendable () -> Date
    private let nonceSource: @Sendable () -> Data

    /// Creates the method over the payer's signing key.
    ///
    /// - Parameters:
    ///   - payerPrivateKey: the 32-byte secp256k1 key that signs the authorization and is the
    ///     `did:pkh` source; its public key fixes the payer address (the EIP-3009 `from`).
    ///   - defaultChainId: the chain to use when the challenge omits `methodDetails.chainId`
    ///     (defaults to Base mainnet).
    ///   - approval: the pre-sign spending gate (defaults to ``X402ApprovalPolicy/allowAll``,
    ///     deferring to the flow's ``PaymentAuthorizer``).
    ///   - now: the clock used to compute `validBefore` (defaults to `Date.init`).
    ///   - nonceSource: the 32-byte `bytes32` nonce source (defaults to a system CSPRNG); injected
    ///     for deterministic tests.
    /// - Returns: `nil` only if a valid payer address cannot be derived from `payerPrivateKey`.
    public init?(
        payerPrivateKey: Data,
        defaultChainId: UInt64 = X402Chain.baseMainnet,
        approval: X402ApprovalPolicy = .allowAll,
        now: @escaping @Sendable () -> Date = Date.init,
        nonceSource: @escaping @Sendable () -> Data = X402ChargeMethod.secureNonce
    ) {
        guard let signer = try? Secp256k1Signer(privateKey: payerPrivateKey),
              let payer = EthereumAddress(uncompressedPublicKey: signer.publicKey)
        else { return nil }
        self.signer = signer
        self.payer = payer
        self.defaultChainId = defaultChainId
        self.approval = approval
        self.now = now
        self.nonceSource = nonceSource
    }

    /// The payer address derived from the signing key, signed-from and named in the `did:pkh`
    /// source.
    public var address: EthereumAddress {
        payer
    }

    /// The `Accept-Payment` ranges this method satisfies: the x402 (`exact`) charge method/intent.
    /// Derived (not hardcoded), so advertising stays tied to the registered method.
    public var paymentRanges: [PaymentRange] {
        [Self.chargeRange]
    }

    /// Whether this is an `x402` / `charge` challenge with a decodable **non-zero** request that
    /// carries a valid-address `recipient` and `currency` and the token's EIP-712 domain
    /// (`name` + `version`) -- everything needed to build and sign the authorization.
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == X402Method.name, challenge.intent == .charge,
              let request = try? X402ChargeRequest(challenge: challenge),
              request.amount.rawValue != "0",
              let recipient = request.recipient, EthereumAddress(hex: recipient) != nil,
              let currency = request.currency, EthereumAddress(hex: currency) != nil,
              request.tokenName != nil, request.tokenVersion != nil
        else { return false }
        return true
    }

    /// The approval facts for `challenge`, filled from the decoded charge request.
    public func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest {
        guard let request = try? X402ChargeRequest(challenge: challenge) else {
            return PaymentApprovalRequest(generic: challenge)
        }
        return PaymentApprovalRequest(
            challengeId: challenge.id, realm: challenge.realm,
            method: challenge.method, intent: challenge.intent,
            amount: request.amount, currency: request.currency, recipient: request.recipient,
            description: challenge.description, expires: challenge.expires
        )
    }

    /// Builds the x402 exact-scheme credential for `challenge`: a signed EIP-3009 authorization.
    ///
    /// - Throws: ``X402ChargeError`` for a malformed/zero/under-specified request, an authorization
    ///   that cannot be formed (e.g. a non-32-byte nonce), or a signing failure.
    public func buildCredential(for challenge: Challenge) async throws -> Credential {
        guard challenge.method == X402Method.name, challenge.intent == .charge else {
            throw X402ChargeError.wrongMethodOrIntent
        }
        let request: X402ChargeRequest
        do {
            request = try X402ChargeRequest(challenge: challenge)
        } catch {
            throw X402ChargeError.malformedRequest(error)
        }
        guard request.amount.rawValue != "0" else { throw X402ChargeError.zeroAmount }
        guard let recipientHex = request.recipient,
              let recipient = EthereumAddress(hex: recipientHex)
        else { throw X402ChargeError.missingOrInvalidRecipient }
        guard let assetHex = request.currency, let asset = EthereumAddress(hex: assetHex)
        else { throw X402ChargeError.missingOrInvalidCurrency }
        guard let name = request.tokenName, let version = request.tokenVersion else {
            throw X402ChargeError.missingTokenDomain
        }
        // Pre-sign gate: refuse before producing a real-money authorization signature.
        guard await approval.approves(approvalFacts(for: challenge)) else {
            throw X402ChargeError.approvalDenied
        }

        let chainId = request.chainId ?? defaultChainId
        let timeout = request.maxTimeoutSeconds ?? Self.defaultTimeoutSeconds
        // A saturating add: `max(0, ...)` keeps a pre-epoch clock from trapping the UInt64
        // conversion, and reporting-overflow keeps a hostile near-UInt64.max `maxTimeoutSeconds`
        // from overflowing and trapping -- fail safe, not crash. The token enforces the deadline.
        let nowSeconds = UInt64(max(0, now().timeIntervalSince1970))
        let (sum, overflowed) = nowSeconds.addingReportingOverflow(timeout)
        let validBefore = overflowed ? UInt64.max : sum

        guard let authorization = X402Authorization(
            from: payer, recipient: recipient, value: request.amount,
            validAfter: 0, validBefore: validBefore, nonce: nonceSource()
        ) else {
            throw X402ChargeError.invalidAuthorization
        }
        let domain = X402Domain(name: name, version: version, chainId: chainId, asset: asset)
        let signature: Data
        do {
            signature = try authorization.sign(domain: domain, with: signer)
        } catch {
            throw X402ChargeError.signingFailed(String(describing: error))
        }

        let exact = X402ExactPayload(authorization: authorization, signature: signature)
        return Credential(
            challenge: challenge,
            source: ProofSource.did(address: payer, chainId: chainId),
            payload: exact.credentialPayload()
        )
    }

    /// 32 cryptographically-random bytes from the system CSPRNG -- the default `bytes32` nonce.
    public static func secureNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
    }

    /// The `exact` / `charge` advertisement range, built once.
    private static let chargeRange: PaymentRange = {
        guard let range = try? PaymentRange(
            method: .value(X402Method.name), intent: .value(.charge)
        ) else {
            preconditionFailure("exact/charge with default quality is a valid range")
        }
        return range
    }()
}

/// A reason ``X402ChargeMethod`` could not build a credential.
public enum X402ChargeError: Error, Sendable, Hashable {
    /// The challenge is not an x402 charge (wrong `method` or `intent`).
    case wrongMethodOrIntent
    /// The challenge `request` could not be decoded.
    case malformedRequest(X402ChargeRequest.DecodingFailure)
    /// The charge `amount` was zero; x402 settles a non-zero transfer.
    case zeroAmount
    /// The request had no `recipient`, or it was not an address.
    case missingOrInvalidRecipient
    /// The request had no `currency` (the token/asset), or it was not an address.
    case missingOrInvalidCurrency
    /// The request did not carry the token's EIP-712 domain (`name` + `version`).
    case missingTokenDomain
    /// The pre-sign approval policy refused the charge.
    case approvalDenied
    /// The authorization could not be formed (e.g. the nonce was not 32 bytes).
    case invalidAuthorization
    /// Signing the authorization failed; carries the underlying error's description.
    case signingFailed(String)
}

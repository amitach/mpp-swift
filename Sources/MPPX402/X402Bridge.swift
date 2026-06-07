import Foundation
import MPPCore
import MPPEVM

/// Translates between this SDK's MPP x402 rail and the real x402 ecosystem's wire, so an MPP server
/// can advertise its `exact`/charge challenge to x402 clients and the SDK's signed credential can
/// pay a real x402 resource server. The reverse directions (consuming an x402 402 / an inbound
/// `X-PAYMENT`) reuse the same wire types and the rail's own decoders.
public enum X402Bridge {
    /// Translates an MPP `exact` / `charge` challenge into the x402 ``X402PaymentRequirements`` a
    /// resource server advertises in its 402 `accepts`.
    ///
    /// - Throws: ``X402BridgeError`` if the challenge is not an x402 charge or is missing the
    ///   recipient, token, or EIP-712 domain the requirements need.
    public static func paymentRequirements(
        for challenge: Challenge
    ) throws(X402BridgeError) -> X402PaymentRequirements {
        let request = try chargeRequest(challenge)
        guard let payTo = request.recipient else { throw .missingRecipient }
        guard let asset = request.currency else { throw .missingCurrency }
        guard let name = request.tokenName, let version = request.tokenVersion else {
            throw .missingTokenDomain
        }
        return X402PaymentRequirements(
            scheme: "exact",
            network: X402Network(chainId: request.chainId ?? X402Chain.baseMainnet),
            amount: request.amount,
            asset: asset,
            payTo: payTo,
            maxTimeoutSeconds: request.maxTimeoutSeconds ?? X402ChargeMethod.defaultTimeoutSeconds,
            extra: [
                "name": .string(name),
                "version": .string(version),
                "assetTransferMethod": .string("eip3009"),
            ]
        )
    }

    /// Translates an MPP credential (built by ``X402ChargeMethod``) into the x402
    /// ``X402PaymentPayload`` the client sends in the `X-PAYMENT` / `PAYMENT-SIGNATURE` header,
    /// encoded for `version`.
    ///
    /// - Throws: ``X402BridgeError`` if the credential's challenge is not an x402 charge or its
    ///   payload is not an x402 exact payload.
    public static func paymentPayload(
        version: X402Version, from credential: Credential
    ) throws(X402BridgeError) -> X402PaymentPayload {
        let request = try chargeRequest(credential.challenge)
        guard let exact = X402ExactPayload(credentialPayload: credential.payload) else {
            throw .malformedCredentialPayload
        }
        return X402PaymentPayload(
            version: version, scheme: "exact",
            network: X402Network(chainId: request.chainId ?? X402Chain.baseMainnet),
            payload: exact
        )
    }

    /// Decodes the x402 charge request from `challenge`, requiring it to be an `exact` / `charge`.
    private static func chargeRequest(
        _ challenge: Challenge
    ) throws(X402BridgeError) -> X402ChargeRequest {
        guard challenge.method == X402Method.name, challenge.intent == .charge else {
            throw .notAnX402Charge
        }
        do {
            return try X402ChargeRequest(challenge: challenge)
        } catch {
            throw .malformedRequest(error)
        }
    }
}

/// A reason an MPP <-> x402 translation could not be performed.
public enum X402BridgeError: Error, Sendable, Hashable {
    /// The challenge was not an `exact` (x402) / `charge` challenge.
    case notAnX402Charge
    /// The challenge `request` could not be decoded.
    case malformedRequest(X402ChargeRequest.DecodingFailure)
    /// The challenge carried no `recipient` (the x402 `payTo`).
    case missingRecipient
    /// The challenge carried no `currency` (the x402 `asset`).
    case missingCurrency
    /// The challenge carried no token EIP-712 domain (`name` + `version`).
    case missingTokenDomain
    /// The credential payload was not an x402 exact payload.
    case malformedCredentialPayload
}

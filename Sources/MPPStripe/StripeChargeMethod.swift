import Foundation
import MPPClient
import MPPCore

/// The Stripe charge payment method, client side.
///
/// It pays a `stripe`/`charge` challenge by presenting a Stripe **Shared Payment Token (SPT)** in
/// the credential; the server settles by creating a Stripe PaymentIntent from it. The SPT is
/// obtained through an injected ``StripeTokenProvider`` (there is no Stripe.js in Swift), which
/// also serves as the pre-pay gate. This type only routes and assembles the ``Credential``; it
/// holds no Stripe secret and makes no network call.
///
/// The credential carries no payer `source` (Stripe identifies the payer by the SPT, not a wallet
/// DID), matching the reference SDK.
public struct StripeChargeMethod: PaymentMethodClient {
    private let tokenProvider: StripeTokenProvider
    private let externalId: String?

    /// Creates the method.
    /// - Parameters:
    ///   - tokenProvider: supplies the SPT for a charge (and gates it by refusing).
    ///   - externalId: an optional caller-side external reference echoed into the credential
    ///     payload (and, server-side, into the receipt); defaults to none.
    public init(tokenProvider: StripeTokenProvider, externalId: String? = nil) {
        self.tokenProvider = tokenProvider
        self.externalId = externalId
    }

    /// The `Accept-Payment` range this method satisfies: `stripe`/`charge`, derived (not
    /// hardcoded) so advertising stays tied to the registered method.
    public var paymentRanges: [PaymentRange] {
        [Self.chargeRange]
    }

    /// Whether this is a `stripe`/`charge` challenge with a decodable request (a non-empty
    /// `paymentMethodTypes` included). A decode failure maps to `false`; the throwing decode is
    /// re-run in ``buildCredential(for:)``, which surfaces the specific reason.
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == StripeMethod.name, challenge.intent == .charge,
              (try? StripeChargeRequest(challenge: challenge)) != nil
        else { return false }
        return true
    }

    /// The approval facts for `challenge`, filling amount/currency/recipient from the
    /// decoded charge request (the same fields the ``StripeTokenRequest`` carries).
    /// An undecodable request falls back to the rail-agnostic facts.
    public func approvalFacts(for challenge: Challenge) -> PaymentApprovalRequest {
        guard let request = try? StripeChargeRequest(challenge: challenge) else {
            return PaymentApprovalRequest(generic: challenge)
        }
        return PaymentApprovalRequest(
            challengeId: challenge.id, realm: challenge.realm,
            method: challenge.method, intent: challenge.intent,
            amount: request.amount, currency: request.currency, recipient: request.recipient,
            description: challenge.description, expires: challenge.expires
        )
    }

    /// Builds the SPT credential for `challenge`.
    ///
    /// Re-checks method/intent (authoritative, this method is public), decodes the request, asks
    /// the token provider for an SPT (its refusal is the pre-pay gate), and assembles the
    /// credential with the `{spt, externalId?}` payload and no `source`.
    ///
    /// - Throws: ``StripeMethodError`` for a wrong method/intent, a malformed request, or a token
    ///   provider that refused.
    public func buildCredential(for challenge: Challenge) async throws -> Credential {
        guard challenge.method == StripeMethod.name, challenge.intent == .charge else {
            throw StripeMethodError.wrongMethodOrIntent
        }
        let request: StripeChargeRequest
        do {
            request = try StripeChargeRequest(challenge: challenge)
        } catch {
            throw StripeMethodError.malformedRequest(error)
        }
        let tokenRequest = StripeTokenRequest(
            challengeId: challenge.id,
            realm: challenge.realm,
            amount: request.amount,
            currency: request.currency,
            description: request.description,
            recipient: request.recipient,
            networkId: request.networkId,
            paymentMethodTypes: request.paymentMethodTypes,
            metadata: request.metadata,
            expires: challenge.expires
        )
        let spt: String
        do {
            spt = try await tokenProvider.token(for: tokenRequest)
        } catch {
            throw StripeMethodError.tokenProviderFailed(error)
        }
        var payload: [String: JSONValue] = ["spt": .string(spt)]
        if let externalId {
            payload["externalId"] = .string(externalId)
        }
        return Credential(challenge: challenge, source: nil, payload: payload)
    }

    /// The `stripe`/`charge` advertisement range, built once. `PaymentRange` only throws on an
    /// out-of-range quality, and the default quality is in range, so this cannot fail.
    private static let chargeRange: PaymentRange = {
        guard let range = try? PaymentRange(
            method: .value(StripeMethod.name), intent: .value(.charge)
        ) else {
            preconditionFailure("stripe/charge with default quality is a valid range")
        }
        return range
    }()
}

/// A reason ``StripeChargeMethod`` could not build a credential.
///
/// Unlike `TempoMethodError`, this is not `Hashable`: ``tokenProviderFailed(_:)`` wraps an
/// arbitrary provider error (`any Error`), which is not `Hashable`. Callers match cases rather
/// than use the error as a set member or dictionary key.
public enum StripeMethodError: Error, Sendable {
    /// The challenge is not a Stripe charge (wrong `method` or `intent`).
    case wrongMethodOrIntent
    /// The challenge `request` could not be decoded.
    case malformedRequest(StripeChargeRequest.DecodingFailure)
    /// The token provider refused to supply an SPT (the pre-pay gate, or an out-of-band failure).
    case tokenProviderFailed(any Error)
}

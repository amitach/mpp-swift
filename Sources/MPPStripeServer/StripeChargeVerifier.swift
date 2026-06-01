import Foundation
import MPPCore
import MPPServer
import MPPStripe

/// The context a dynamic Connect resolver sees for a charge: the challenge binding, the decoded
/// request, and the credential `source` (usually nil for Stripe).
public struct StripeConnectContext: Sendable {
    public let challengeID: String
    public let realm: String
    public let request: StripeChargeRequest
    public let source: String?

    /// Public so a consumer can construct one to unit-test its own ``StripeConnect`` resolver in
    /// isolation (the verifier builds it during a charge).
    public init(challengeID: String, realm: String, request: StripeChargeRequest, source: String?) {
        self.challengeID = challengeID
        self.realm = realm
        self.request = request
        self.source = source
    }
}

/// The server's Connect-settlement policy: a fixed settlement, or a resolver that decides per
/// charge. Mirrors the reference SDK's `ConnectSettlement | ResolveConnectSettlement`.
public struct StripeConnect: Sendable {
    let resolve: @Sendable (StripeConnectContext) async -> StripeConnectSettlement?

    /// A resolver invoked per charge.
    public init(_ resolve: @escaping @Sendable (StripeConnectContext) async
        -> StripeConnectSettlement?) {
        self.resolve = resolve
    }

    /// A fixed settlement applied to every charge.
    public static func fixed(_ settlement: StripeConnectSettlement) -> StripeConnect {
        StripeConnect { _ in settlement }
    }
}

/// The Stripe charge payment method, server side.
///
/// Verifies a `stripe`/`charge` credential by creating a Stripe PaymentIntent from the Shared
/// Payment Token the credential carries (via the injected ``StripePaymentIntentCreating`` seam),
/// and maps the PaymentIntent status to a receipt or a rejection. The challenge's expiry and the
/// single-use replay consume are enforced by ``PaymentVerifier`` before this runs, so the verifier
/// does not re-check them; Stripe's `idempotent-replayed` is mapped as defense-in-depth.
public struct StripeChargeVerifier: PaymentMethodServer {
    private let client: any StripePaymentIntentCreating
    private let connect: StripeConnect?

    /// Creates the verifier.
    /// - Parameters:
    ///   - client: creates the PaymentIntent (the concrete client posts to Stripe; tests stub it).
    ///   - connect: an optional server-configured Connect settlement policy (default: none).
    public init(client: any StripePaymentIntentCreating, connect: StripeConnect? = nil) {
        self.client = client
        self.connect = connect
    }

    /// Whether this is a `stripe`/`charge` challenge with a decodable request.
    public func supports(_ challenge: Challenge) -> Bool {
        guard challenge.method == StripeMethod.name, challenge.intent == .charge,
              (try? StripeChargeRequest(challenge: challenge)) != nil
        else { return false }
        return true
    }

    /// Verifies the credential by settling a PaymentIntent and returns the receipt.
    ///
    /// - Throws: ``VerifyError`` for a malformed request, an over-range amount, a missing SPT, an
    ///   invalid Connect settlement, a PaymentIntent that requires action / was replayed / settled
    ///   to a non-`succeeded` status, or a PaymentIntent-creation failure.
    public func verify(_ credential: Credential, now: Date) async throws(VerifyError) -> Receipt {
        let challenge = credential.challenge
        let request: StripeChargeRequest
        do {
            request = try StripeChargeRequest(challenge: challenge)
        } catch {
            throw .malformedRequest(error)
        }
        // The only crossing out of the canonical-string amount domain; fail closed on overflow.
        guard let amount = Int(request.amount.rawValue) else { throw .amountOverflow }

        guard case let .string(spt)? = credential.payload["spt"], !spt.isEmpty else {
            throw .missingSPT
        }
        let externalID: String? = if case let .string(value)? = credential.payload["externalId"] {
            value
        } else {
            nil
        }

        let settlement = await resolveSettlement(
            challenge: challenge,
            request: request,
            credential: credential
        )
        if let violation = StripeConnectViolation.violation(in: settlement, amount: amount) {
            throw .connectInvalid(violation)
        }

        let intentRequest = paymentIntentRequest(
            credential: credential, request: request, amount: amount, spt: spt,
            settlement: settlement
        )
        let result: StripePaymentIntentResult
        do {
            result = try await client.create(intentRequest)
        } catch {
            throw .paymentIntentFailed(error)
        }

        if result.replayed { throw .alreadyProcessed }
        if result.status == "requires_action" { throw .paymentActionRequired }
        guard result.status == "succeeded" else { throw .unexpectedStatus(result.status) }

        var extras: [String: Receipt.ReceiptValue] = [:]
        if let externalID { extras["externalId"] = .string(externalID) }
        return Receipt(
            method: challenge.method,
            timestamp: RFC3339DateTime(date: now),
            reference: result.id,
            extras: extras
        )
    }

    private func paymentIntentRequest(
        credential: Credential, request: StripeChargeRequest, amount: Int, spt: String,
        settlement: StripeConnectSettlement?
    ) -> StripePaymentIntentRequest {
        let challenge = credential.challenge
        let analytics = StripeAnalyticsMetadata.build(
            challengeID: challenge.id, realm: challenge.realm,
            intent: challenge.intent.rawValue, source: credential.source
        )
        let metadata = StripeAnalyticsMetadata.merged(analytics: analytics, user: request.metadata)
        return StripePaymentIntentRequest(
            amount: amount,
            currency: request.currency,
            sharedPaymentGrantedToken: spt,
            metadata: metadata,
            idempotencyKey: StripeIdempotencyKey.derive(challengeID: challenge.id, spt: spt),
            settlement: settlement
        )
    }

    private func resolveSettlement(
        challenge: Challenge, request: StripeChargeRequest, credential: Credential
    ) async -> StripeConnectSettlement? {
        guard let connect else { return nil }
        let context = StripeConnectContext(
            challengeID: challenge.id, realm: challenge.realm,
            request: request, source: credential.source
        )
        return await connect.resolve(context)
    }

    /// A reason ``StripeChargeVerifier`` rejected a credential.
    ///
    /// Not `Hashable`: ``paymentIntentFailed(_:)`` wraps an arbitrary client error (`any Error`).
    public enum VerifyError: Error, Sendable {
        /// The challenge `request` could not be decoded.
        case malformedRequest(StripeChargeRequest.DecodingFailure)
        /// The charge `amount` did not fit a 64-bit integer.
        case amountOverflow
        /// The credential payload had no non-empty `spt`.
        case missingSPT
        /// The configured Connect settlement was invalid (validated before any Stripe call).
        case connectInvalid(StripeConnectViolation)
        /// The PaymentIntent requires customer action (e.g. 3D Secure); not settleable here.
        case paymentActionRequired
        /// Stripe replayed an idempotent request: this charge was already processed.
        case alreadyProcessed
        /// The PaymentIntent settled to a status other than `succeeded` (the carried raw status).
        case unexpectedStatus(String)
        /// Creating the PaymentIntent failed (the underlying client error).
        case paymentIntentFailed(any Error)
    }
}

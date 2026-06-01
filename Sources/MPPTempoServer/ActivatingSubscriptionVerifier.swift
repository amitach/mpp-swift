import Foundation
import MPPCore
import MPPServer

/// A ``PaymentMethodServer`` that verifies a `tempo`/`subscription` activation **and persists it**:
/// it wraps ``TempoSubscriptionVerifier`` and, on a successful verify, builds the
/// ``SubscriptionRecord`` and stores it via ``SubscriptionEngine/activate(_:now:)`` so the renewal
/// engine can charge it. This is the server route that turns the verify-and-persist seam into a
/// live persist: because `verify(_:now:)` is `async`, the activation is awaited inline (no separate
/// hook), and a store write failure rejects the payment (the client retries on a fresh `402`).
///
/// `subscriptionID` and `lookupKey` are application identity (which customer/plan), not in the
/// credential, so they come from an injected `resolveIdentity` hook (typically the auth context the
/// 402 was issued under). `billingAnchor` is the verify instant; `lastChargedPeriod` stays `nil`
/// (the verifier settles no value, so the renewal engine charges period 0 onward).
public struct ActivatingSubscriptionVerifier: PaymentMethodServer {
    /// The application identity a verified subscription is recorded under.
    public struct Identity: Sendable, Hashable {
        public let subscriptionID: String
        public let lookupKey: String

        public init(subscriptionID: String, lookupKey: String) {
            self.subscriptionID = subscriptionID
            self.lookupKey = lookupKey
        }
    }

    private let verifier: TempoSubscriptionVerifier
    private let engine: SubscriptionEngine
    private let resolveIdentity: @Sendable (Credential) async throws -> Identity

    /// Creates the activating verifier.
    /// - Parameters:
    ///   - verifier: the underlying re-encode-and-compare subscription verifier.
    ///   - engine: the engine whose ``SubscriptionEngine/activate(_:now:)`` persists the record.
    ///   - resolveIdentity: maps a verified credential to its `(subscriptionID, lookupKey)` (the
    ///     customer/plan this 402 was issued for).
    public init(
        verifier: TempoSubscriptionVerifier,
        engine: SubscriptionEngine,
        resolveIdentity: @escaping @Sendable (Credential) async throws -> Identity
    ) {
        self.verifier = verifier
        self.engine = engine
        self.resolveIdentity = resolveIdentity
    }

    public func supports(_ challenge: Challenge) -> Bool {
        verifier.supports(challenge)
    }

    /// Activation is one-shot, like the underlying verifier: the challenge id is consumed once.
    public var reusesChallenge: Bool {
        verifier.reusesChallenge
    }

    public func verify(_ credential: Credential, now: Date) async throws -> Receipt {
        let verified = try verifier.verified(credential, now: now)
        let identity = try await resolveIdentity(credential)
        let seconds = UInt64(now.timeIntervalSince1970)
        _ = try await engine.activate(
            verified,
            subscriptionID: identity.subscriptionID,
            lookupKey: identity.lookupKey,
            billingAnchor: seconds,
            now: seconds
        )
        // The same activation receipt the underlying verifier mints (reference = the challenge id;
        // activation settles no value on-chain, the recurring transfers do).
        let challenge = credential.challenge
        return Receipt(
            method: challenge.method, timestamp: RFC3339DateTime(date: now), reference: challenge.id
        )
    }
}

import Foundation
import HTTPTypes
import MPPCore
import MPPServer

/// A ``RequestAuthorizer`` that lets a returning subscriber through a payment-protected route
/// without
/// a fresh credential, charging the due period inline (the mppx-faithful "lazy renewal").
///
/// On a credential-less request the middleware calls ``authorize(_:body:now:)``: it resolves the
/// caller's subscription identity via ``resolveLookupKey``, finds the active subscription, and
/// renews
/// through ``SubscriptionEngine`` if a period is due. Outcomes:
/// - renewed or already up to date -> ``AuthorizeOutcome/authorized(_:)`` with a `Payment-Receipt`,
/// - another renewer holds the period -> `409` with `Retry-After`,
/// - a transient charge failure (the engine released its claim) -> `503` with `Retry-After`,
/// - canceled / revoked / expired / superseded -> fall through (`nil`) to the `402` activation
/// path.
///
/// Identity is application-specific (a bearer token, an API key, an authenticated user), so the
/// caller supplies ``resolveLookupKey``; returning `nil` for a request that is not a recognized
/// returning subscriber falls through to the normal `402` / activation path. The renewal charges
/// on-chain through the engine's ``SubscriptionRenewer``.
///
/// Multi-instance note: exactly-once holds per process via the store's serialized update; a
/// deployment running more than one instance must back the engine with a durable,
/// atomically-updating
/// ``SubscriptionStore`` so the renewal claim is shared across instances.
public struct SubscriptionAuthorizer: RequestAuthorizer {
    private let engine: SubscriptionEngine
    private let routeMethod: MethodName
    private let resolveLookupKey: @Sendable (HTTPRequest) async -> String?

    /// Creates an authorizer over a subscription engine.
    ///
    /// - Parameters:
    ///   - engine: the subscription engine; its store is the active-subscription source of truth.
    ///   - routeMethod: the payment method id stamped into the renewal receipt (for example
    /// `tempo`).
    ///   - resolveLookupKey: maps a request to its subscription `lookupKey`, or `nil` when the
    /// request
    ///     is not a recognized returning subscriber (then the middleware mints a `402`).
    public init(
        engine: SubscriptionEngine,
        routeMethod: MethodName,
        resolveLookupKey: @escaping @Sendable (HTTPRequest) async -> String?
    ) {
        self.engine = engine
        self.routeMethod = routeMethod
        self.resolveLookupKey = resolveLookupKey
    }

    public func authorize(
        _ request: HTTPRequest, body _: Data, now: Date
    ) async -> AuthorizeOutcome? {
        guard let lookupKey = await resolveLookupKey(request),
              let subscriptionID = await engine.activeSubscription(forLookupKey: lookupKey)
        else { return nil }

        let seconds = UInt64(now.timeIntervalSince1970)
        let outcome: RenewalOutcome
        do {
            outcome = try await engine.renew(subscriptionID: subscriptionID, now: seconds)
        } catch SubscriptionError.notFound {
            // The record vanished between the active-subscription read and renew (a TOCTOU window,
            // e.g. a concurrent removal). That is permanent, not transient, so fall through to the
            // 402 / activation path rather than telling the client to retry forever. Caught
            // specifically (not `is SubscriptionError`) so any other engine error stays transient.
            return nil
        } catch {
            // A transient charge failure: the engine released its claim, so a later attempt
            // recharges. Ask the client to retry shortly rather than serving without settlement.
            return Self.retry(.serviceUnavailable)
        }

        switch outcome {
        case let .renewed(_, reference):
            return .authorized(receipt(reference: reference, now: now))
        case .upToDate:
            // Already charged for the due period: authorize with the last settlement reference.
            let reference = await engine.record(subscriptionID)?.lastReference ?? subscriptionID
            return .authorized(receipt(reference: reference, now: now))
        case .inFlight:
            // Another renewer holds the period; ask the client to retry in a moment.
            return Self.retry(.conflict)
        case .inactive:
            // Canceled, revoked, expired, or superseded: not chargeable. Fall through to a 402 so
            // the
            // caller can re-subscribe.
            return nil
        }
    }

    private func receipt(reference: String, now: Date) -> Receipt {
        Receipt(method: routeMethod, timestamp: RFC3339DateTime(date: now), reference: reference)
    }

    /// A bodyless retry outcome (`Retry-After: 1`, `Cache-Control: no-store`) for the in-flight
    /// (`409`) and transient-failure (`503`) cases.
    private static func retry(_ status: HTTPResponse.Status) -> AuthorizeOutcome {
        var fields = HTTPFields()
        fields[.retryAfter] = "1"
        fields[.cacheControl] = "no-store"
        return .respond(HTTPResponse(status: status, headerFields: fields), Data())
    }
}

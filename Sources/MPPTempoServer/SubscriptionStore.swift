import Foundation

/// Persistence for ``SubscriptionRecord`` with atomic read-modify-write, plus the
/// `lookupKey -> subscriptionID` pointer to the active subscription for a customer
/// or plan.
///
/// This is the same plug-in seam as `ChannelStore`: an in-memory implementation
/// suits a single process; a deployment that shares subscriptions across instances
/// backs it with a store offering atomic updates. The atomicity of ``update(_:_:)``
/// is what lets ``SubscriptionEngine`` claim a renewal exactly once across
/// concurrent renewers.
public protocol SubscriptionStore: Sendable {
    /// The current record for `subscriptionID`, or `nil` if unknown.
    func record(_ subscriptionID: String) async -> SubscriptionRecord?

    /// Atomically reads the record for `subscriptionID`, applies `transform`, and
    /// stores the result (or removes it when `transform` returns `nil`). `transform`
    /// runs under the store's serialization, so its read-modify-write is atomic; it
    /// may throw to abort the update without writing.
    @discardableResult
    func update(
        _ subscriptionID: String,
        _ transform: @Sendable (SubscriptionRecord?) throws -> SubscriptionRecord?
    ) async throws -> SubscriptionRecord?

    /// The subscription id currently active for `lookupKey`, or `nil` if none.
    func activeSubscription(forLookupKey lookupKey: String) async -> String?

    /// Points `lookupKey` at `subscriptionID` as its active subscription.
    func setActiveSubscription(_ subscriptionID: String, forLookupKey lookupKey: String) async
}

/// An in-memory ``SubscriptionStore`` backed by an actor, suitable for a single
/// process and for tests. The actor serializes ``update(_:_:)``, giving the atomic
/// read-modify-write guarantee the renewal claim relies on.
public actor InMemorySubscriptionStore: SubscriptionStore {
    private var records: [String: SubscriptionRecord] = [:]
    private var active: [String: String] = [:]

    public init() {}

    public func record(_ subscriptionID: String) -> SubscriptionRecord? {
        records[subscriptionID]
    }

    @discardableResult
    public func update(
        _ subscriptionID: String,
        _ transform: @Sendable (SubscriptionRecord?) throws -> SubscriptionRecord?
    ) throws -> SubscriptionRecord? {
        let next = try transform(records[subscriptionID])
        records[subscriptionID] = next
        return next
    }

    public func activeSubscription(forLookupKey lookupKey: String) -> String? {
        active[lookupKey]
    }

    public func setActiveSubscription(_ subscriptionID: String, forLookupKey lookupKey: String) {
        active[lookupKey] = subscriptionID
    }
}

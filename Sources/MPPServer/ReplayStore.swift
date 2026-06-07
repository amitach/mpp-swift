/// Records which challenge ids have been used, so a paid credential cannot be
/// replayed.
///
/// Per `draft-httpauth-payment-00` §11.3 / §11.5, each challenge is single-use:
/// the server must consume the challenge id atomically before delivering the
/// paid response, and ``consume(_:)`` is the serialization point under
/// concurrency. The first consume of an id wins; any later consume of the same
/// id is a replay and is rejected.
public protocol ReplayStore: Sendable {
    /// Marks `id` as used and reports whether this was its first use.
    ///
    /// - Returns: `true` if `id` had not been consumed before (accept the
    ///   payment); `false` if it was already consumed (a replay: reject). The
    ///   check-and-record is atomic: for concurrent calls with the same `id`,
    ///   exactly one returns `true`.
    ///
    /// The method does not throw, on purpose: it must always render a
    /// accept-or-reject decision. An implementation that cannot determine first
    /// use (for example a backing store is unavailable) MUST **fail closed** and
    /// return `false` (reject), never accept a payment it cannot prove is
    /// un-replayed. A throwing signature would invite a caller to treat a store
    /// error as a retry/500 and accidentally fail open.
    func consume(_ id: String) async -> Bool
}

/// An in-memory ``ReplayStore`` backed by an actor, suitable for a single
/// process and for tests.
///
/// The actor serializes ``consume(_:)``, giving the atomic first-wins guarantee.
/// It retains every consumed id for the process lifetime; a store that bounds
/// memory by expiring ids (SQLite/Redis with a TTL) is a separate implementation
/// of ``ReplayStore``.
///
/// > Important: the single-use guarantee this store provides is **per process and
/// > volatile**. Consumed ids live only in this process's memory, so a credential
/// > consumed before a restart can be replayed after one, and two instances behind
/// > a load balancer each accept the same credential once. For any deployment that
/// > spans process restarts or more than one instance, use a **durable, shared**
/// > ``ReplayStore`` instead: ``FileReplayStore`` persists across restarts on a
/// > single host, and a SQLite/Redis-backed store covers the multi-instance case.
/// > This type is for a single long-lived process and for tests.
public actor InMemoryReplayStore: ReplayStore {
    private var consumed: Set<String> = []

    /// Creates an empty store.
    public init() {}

    public func consume(_ id: String) -> Bool {
        consumed.insert(id).inserted
    }
}

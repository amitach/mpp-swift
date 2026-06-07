/// Persists the ``Receipt``s a payer collects (or a payee mints), giving a consumer that needs a
/// durable record of settled payments (a ledger, a reconciliation job, a dispute trail) one place
/// to receive them.
///
/// Rail-agnostic: a receipt is the protocol's settlement record regardless of the method that
/// produced it, so this seam takes a ``Receipt`` and knows nothing about any specific rail. The
/// client records the receipts it earns; a server can record the ones it mints.
///
/// ``record(_:)`` does not throw, on purpose. By the time a receipt exists the payment has already
/// settled, so a persistence failure must not fail the response the payer already earned (the 402
/// flow treats the receipt as auditing, not a gate). An implementation whose backend can fail
/// should log and recover internally; one that needs guaranteed durability should make its write
/// durable (a write-ahead log or transaction) rather than rely on the caller to retry.
public protocol ReceiptStore: Sendable {
    /// Records `receipt`. Best-effort: it never throws. The 402 client awaits it after the payment
    /// has settled (so the receipt is recorded before the caller proceeds), so a durable
    /// implementation should keep the write fast or hand it off to its own queue rather than block.
    func record(_ receipt: Receipt) async
}

/// An in-memory ``ReceiptStore`` backed by an actor, suitable for a single process and for tests
/// (and for emulating a hosted ledger locally during development).
///
/// It retains every recorded receipt for the process lifetime, in record order. A durable,
/// bounded, or shared store (SQLite/Postgres) is a separate implementation of ``ReceiptStore``.
public actor InMemoryReceiptStore: ReceiptStore {
    private var stored: [Receipt] = []

    /// Creates an empty store.
    public init() {}

    public func record(_ receipt: Receipt) {
        stored.append(receipt)
    }

    /// The receipts recorded so far, in record order.
    public var receipts: [Receipt] {
        stored
    }
}

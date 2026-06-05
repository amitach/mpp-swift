import Foundation

/// The decision a ``RateLimiter`` renders for one unit of work.
public enum RateLimitDecision: Sendable, Hashable {
    /// Within budget; the request proceeds.
    case allowed
    /// Over budget; reject with `429` and a `Retry-After` of at least `retryAfter` seconds (the
    /// time until the next unit becomes available).
    case limited(retryAfter: TimeInterval)
}

/// A per-client rate limiter, the DoS seam an ``MPPServerMiddleware`` consults before any payment
/// work (`draft-httpauth-payment-00` §11.12).
///
/// The middleware does not know the transport remote address, so the caller supplies the client
/// `key` (for example a reverse proxy's `X-Forwarded-For`, or the authenticated identity); a
/// request that yields no key is not limited. Like ``ReplayStore``, ``reserve(_:now:)`` does not
/// throw: it always renders an allow-or-limit decision. `now` is injected (never the system clock)
/// so behavior is deterministic under a fixed test clock.
public protocol RateLimiter: Sendable {
    /// Reserves one unit of work for `key` as of `now`, returning ``RateLimitDecision/allowed`` or
    /// ``RateLimitDecision/limited(retryAfter:)``.
    func reserve(_ key: String, now: Date) async -> RateLimitDecision
}

/// An in-memory token-bucket ``RateLimiter``: each `key` gets a bucket of `burst` tokens that
/// refills at `refillPerSecond` tokens per second; a reserve consumes one token when available,
/// otherwise reports the wait until one is. A short `burst` smooths spikes; `refillPerSecond` sets
/// the sustained rate.
///
/// Suitable for a single process. It retains one bucket per key for the process lifetime, so an
/// adversary flooding with distinct keys grows memory unbounded (the same caveat as
/// ``InMemoryReplayStore``); a deployment that needs key eviction or cross-instance limits backs
/// the ``RateLimiter`` seam with a shared store (Redis), exactly as for the replay store.
public actor InMemoryRateLimiter: RateLimiter {
    private struct Bucket {
        var tokens: Double
        var updatedAt: Date
    }

    private let capacity: Double
    private let refillPerSecond: Double
    private var buckets: [String: Bucket] = [:]

    /// - Parameters:
    ///   - burst: bucket capacity, the most requests admitted in an instantaneous spike (must be
    ///     `>= 1`).
    ///   - refillPerSecond: the sustained rate, tokens added per second (must be `> 0`).
    public init(burst: Int, refillPerSecond: Double) {
        precondition(burst >= 1, "RateLimiter burst must be >= 1")
        precondition(refillPerSecond > 0, "RateLimiter refillPerSecond must be > 0")
        capacity = Double(burst)
        self.refillPerSecond = refillPerSecond
    }

    public func reserve(_ key: String, now: Date) -> RateLimitDecision {
        var bucket = buckets[key] ?? Bucket(tokens: capacity, updatedAt: now)
        // Refill by elapsed time, clamped to capacity. A non-monotonic (backwards) clock adds no
        // tokens (elapsed clamps to 0) and never moves `updatedAt` backwards: advancing it into
        // the past would make a later, correct-time call see an inflated elapsed and refill a
        // spurious full burst on clock recovery.
        let elapsed = max(0, now.timeIntervalSince(bucket.updatedAt))
        bucket.tokens = min(capacity, bucket.tokens + elapsed * refillPerSecond)
        bucket.updatedAt = max(bucket.updatedAt, now)
        let decision: RateLimitDecision
        if bucket.tokens >= 1 {
            bucket.tokens -= 1
            decision = .allowed
        } else {
            decision = .limited(retryAfter: (1 - bucket.tokens) / refillPerSecond)
        }
        buckets[key] = bucket
        return decision
    }
}

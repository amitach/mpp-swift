import Foundation
import Testing
@testable import MPPServer

// Token-bucket behaviour, deterministic against the fixed `now` (anti-flakiness rule #1: the
// limiter reads the supplied instant, never the system clock).
@Suite("InMemoryRateLimiter (token bucket)")
struct RateLimiterTests {
    private func makeLimiter() -> InMemoryRateLimiter { // burst 3, 1 token/sec
        InMemoryRateLimiter(burst: 3, refillPerSecond: 1)
    }

    @Test("a fresh key admits a full burst, then limits with the right Retry-After")
    func burstThenLimit() async {
        let limiter = makeLimiter()
        for _ in 0 ..< 3 {
            #expect(await limiter.reserve("a", now: now) == .allowed)
        }
        #expect(await limiter.reserve("a", now: now) == .limited(retryAfter: 1)) // 1 token at 1/sec
    }

    @Test("a token is restored after the elapsed refill time")
    func refill() async {
        let limiter = makeLimiter()
        for _ in 0 ..< 3 {
            _ = await limiter.reserve("a", now: now)
        } // drain
        #expect(await limiter.reserve("a", now: now) != .allowed) // empty
        // 2 seconds later: 2 tokens refilled; the next reserve is admitted.
        #expect(await limiter.reserve("a", now: now.addingTimeInterval(2)) == .allowed)
    }

    @Test("refill is capped at the burst capacity, never unbounded")
    func refillCapped() async {
        let limiter = makeLimiter()
        _ = await limiter.reserve("a", now: now) // 3 -> 2
        // A long idle caps tokens at burst (3): exactly 3 admitted, then limited.
        let far = now.addingTimeInterval(10000)
        for _ in 0 ..< 3 {
            #expect(await limiter.reserve("a", now: far) == .allowed)
        }
        #expect(await limiter.reserve("a", now: far) != .allowed)
    }

    @Test("distinct keys have independent buckets")
    func independentKeys() async {
        let limiter = makeLimiter()
        for _ in 0 ..< 3 {
            _ = await limiter.reserve("a", now: now)
        } // drain "a"
        #expect(await limiter.reserve("a", now: now) != .allowed)
        #expect(await limiter.reserve("b", now: now) == .allowed) // "b" is fresh
    }

    @Test("a backwards clock neither drains nor refills, and grants no spurious burst on recovery")
    func backwardsClock() async {
        let limiter = makeLimiter() // burst 3
        _ = await limiter.reserve("a", now: now) // 3 -> 2
        // An earlier instant clamps elapsed to 0: no refill, no spurious drain; the 2 tokens stand.
        #expect(await limiter.reserve("a", now: now.addingTimeInterval(-100)) == .allowed) // 2 -> 1
        // Recovery to the original instant must NOT refill (updatedAt never moved backwards): only
        // the 1 remaining token is available, then limited. (A bucket that moved updatedAt into the
        // past would here see elapsed 100s and hand back a full burst.)
        #expect(await limiter.reserve("a", now: now) == .allowed) // 1 -> 0
        #expect(await limiter.reserve("a", now: now) != .allowed) // 0: limited
    }
}

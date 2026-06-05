import Foundation
import HTTPTypes
import MPPCore
import MPPServer
import Testing

// §11.12 DoS: the middleware throttles via the optional RateLimiter seam before any payment work.
// Shared fixtures (now / makeMiddleware / makeRequest / EventBox / eventNames) live in
// MPPServerTestSupport.
@Suite("MPPServerMiddleware rate limiting")
struct MPPServerMiddlewareRateLimitTests {
    @Test("an over-limit request answers 429 with Retry-After and no-store, before the handler")
    func rateLimited() async throws {
        let box = EventBox()
        let middleware = try makeMiddleware(
            rateLimiter: InMemoryRateLimiter(burst: 1, refillPerSecond: 1),
            rateLimitKey: { _ in "client-1" }, // one key, burst 1 -> the 2nd call is limited
            onEvent: box.add
        )
        let (first, _) = await middleware.handle(makeRequest(), body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        #expect(first.status.code == 402) // first request: within budget, normal 402

        var handlerRan = false
        let (second, body) = await middleware
            .handle(makeRequest(), body: Data(), now: now) { _, _ in
                handlerRan = true
                return (HTTPResponse(status: .ok), Data())
            }
        #expect(second.status.code == 429)
        #expect(try second.headerFields[#require(HTTPField.Name("Retry-After"))] == "1")
        #expect(second.headerFields[.cacheControl] == "no-store")
        #expect(second.headerFields[.contentType] == "application/problem+json")
        #expect(!body.isEmpty)
        #expect(!handlerRan) // the limited request never reaches the protected handler
        #expect(eventNames(box).last == "rateLimited")
    }

    @Test("a request that yields no rate-limit key is never limited")
    func noKeyNoLimit() async throws {
        let middleware = try makeMiddleware(
            rateLimiter: InMemoryRateLimiter(burst: 1, refillPerSecond: 1) // default extractor: nil
        )
        for _ in 0 ..< 5 {
            let (response, _) = await middleware
                .handle(makeRequest(), body: Data(), now: now) { _, _ in
                    (HTTPResponse(status: .ok), Data())
                }
            #expect(response.status.code == 402) // never 429
        }
    }
}

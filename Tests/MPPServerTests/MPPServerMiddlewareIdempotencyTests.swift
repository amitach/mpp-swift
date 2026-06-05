import Foundation
import HTTPTypes
import MPPServer
import Testing

// §11.4 idempotency: with an IdempotencyStore + an `Idempotency-Key`, `handle` replays a settled
// response on retry (no re-charge on the now-spent challenge), answers 409 while one is in flight,
// and records only a settled (handler-run) response.
private actor RunCount {
    private(set) var value = 0
    func bump() {
        value += 1
    }
}

private func idempotentRequest(authorization: String?, key: String) throws -> HTTPRequest {
    var fields = HTTPFields()
    if let authorization { fields[.authorization] = authorization }
    try fields[#require(HTTPField.Name("Idempotency-Key"))] = key
    return HTTPRequest(
        method: .post,
        scheme: "https",
        authority: "api.example.com",
        path: "/r",
        headerFields: fields
    )
}

@Suite("MPPServerMiddleware idempotency")
struct MPPServerMiddlewareIdempotencyTests {
    @Test("a retried settled request replays the recorded response and does not re-run the handler")
    func replaysSettled() async throws {
        let middleware = try makeMiddleware(idempotencyStore: InMemoryIdempotencyStore())
        let runs = RunCount()
        let request = try idempotentRequest(authorization: paidHeader(), key: "K1")
        @Sendable func run() async -> (HTTPResponse, Data) {
            await middleware.handle(request, body: Data(), now: now) { _, _ in
                await runs.bump()
                return (HTTPResponse(status: .ok), Data("served".utf8))
            }
        }
        let (first, firstBody) = await run()
        #expect(first.status.code == 200)
        #expect(firstBody == Data("served".utf8))

        // The retry presents the same (now-spent) credential: without idempotency it would 402 as a
        // replay; with it, the recorded 200 is replayed and the handler does not run again.
        let (second, secondBody) = await run()
        #expect(second.status.code == 200)
        #expect(secondBody == Data("served".utf8))
        #expect(await runs.value == 1) // handler ran exactly once: no re-charge
    }

    @Test("an Idempotency-Key whose request is in flight answers 409 Conflict")
    func conflictWhileInFlight() async throws {
        let store = InMemoryIdempotencyStore()
        _ = await store.begin("K2") // another request holds the key
        let middleware = try makeMiddleware(idempotencyStore: store)
        let request = try idempotentRequest(authorization: paidHeader(), key: "K2")
        let (response, body) = await middleware.handle(request, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        #expect(response.status.code == 409)
        #expect(response.headerFields[.cacheControl] == "no-store")
        #expect(!body.isEmpty)
    }

    @Test("an unsettled (402) request does not cache; the key stays usable for a paid retry")
    func unsettledReleasesKey() async throws {
        let middleware = try makeMiddleware(idempotencyStore: InMemoryIdempotencyStore())
        // No credential -> 402: not served, so the key is released, not recorded.
        let unpaid = try idempotentRequest(authorization: nil, key: "K3")
        let (first, _) = await middleware.handle(unpaid, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        #expect(first.status.code == 402)
        // A paid retry with the same key now settles (the key was freed, not stuck in progress).
        let paid = try idempotentRequest(authorization: paidHeader(), key: "K3")
        let (second, body) = await middleware.handle(paid, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data("paid".utf8))
        }
        #expect(second.status.code == 200)
        #expect(body == Data("paid".utf8))
    }

    @Test("with no Idempotency-Key the store is not consulted (normal flow)")
    func noKeyNormalFlow() async throws {
        let middleware = try makeMiddleware(idempotencyStore: InMemoryIdempotencyStore())
        let request = try makeRequest(authorization: paidHeader())
        let (response, _) = await middleware.handle(request, body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), Data())
        }
        #expect(response.status.code == 200) // settled normally; no idempotency interaction
    }
}

import Foundation
import HTTPTypes
import MPPCore
import Testing
@testable import MPPServer

// The generic credential-less authorize seam on MPPServerMiddleware: tried only when no credential
// is
// present, before minting a 402; `.authorized` lifts into a credential-less MPPVerified and runs
// the
// handler; `.respond` is returned as-is; `nil` falls through to the 402. A middleware with no
// authorizer answers 402 for every credential-less request (no bypass).
@Suite("RequestAuthorizer seam")
struct RequestAuthorizerTests {
    /// A fixed-outcome authorizer for driving each middleware branch.
    private struct StubAuthorizer: RequestAuthorizer {
        let outcome: AuthorizeOutcome?
        func authorize(_: HTTPRequest, body _: Data, now _: Date) async -> AuthorizeOutcome? {
            outcome
        }
    }

    private func receipt() throws -> Receipt {
        try Receipt(
            method: MethodName("tempo"),
            timestamp: RFC3339DateTime("2030-01-01T00:00:00Z"),
            reference: "ref-1"
        )
    }

    private let ran = Data("HANDLER_RAN".utf8)

    @Test(
        "authorized credential-less request runs the handler with a credential-less token + receipt"
    )
    func authorizedServes() async throws {
        let middleware =
            try makeMiddleware(authorizer: StubAuthorizer(outcome: .authorized(receipt())))
        let (response, body) = await middleware.handle(
            makeRequest(), body: Data(), now: now
        ) { _, verified in
            #expect(verified.credential == nil) // the authorize path carries no credential
            #expect(verified.receipt != nil)
            return (HTTPResponse(status: .ok), ran)
        }
        #expect(response.status.code == 200)
        #expect(body == ran)
        // The lifted receipt is attached, and the §11.10 private floor is enforced.
        #expect(try response.headerFields[#require(.init("Payment-Receipt"))] != nil)
        #expect(response.headerFields[.cacheControl] == "private")
    }

    @Test("authorized with no receipt still serves, with no Payment-Receipt header")
    func authorizedNoReceipt() async throws {
        let middleware = try makeMiddleware(authorizer: StubAuthorizer(outcome: .authorized(nil)))
        let (response, body) = await middleware
            .handle(makeRequest(), body: Data(), now: now) { _, _ in
                (HTTPResponse(status: .ok), ran)
            }
        #expect(response.status.code == 200)
        #expect(body == ran)
        #expect(try response.headerFields[#require(.init("Payment-Receipt"))] == nil)
    }

    @Test("a .respond outcome is returned as-is and the handler does not run")
    func respondShortCircuits() async throws {
        var fields = HTTPFields()
        fields[.retryAfter] = "1"
        let stub = StubAuthorizer(outcome: .respond(
            HTTPResponse(status: .conflict, headerFields: fields),
            Data()
        ))
        let middleware = try makeMiddleware(authorizer: stub)
        let (response, body) = await middleware
            .handle(makeRequest(), body: Data(), now: now) { _, _ in
                (HTTPResponse(status: .ok), ran)
            }
        #expect(response.status.code == 409)
        #expect(response.headerFields[.retryAfter] == "1")
        #expect(body != ran) // handler not run
    }

    @Test("a nil outcome falls through to the 402 mint")
    func nilFallsThroughTo402() async throws {
        let middleware = try makeMiddleware(authorizer: StubAuthorizer(outcome: nil))
        let (response, body) = await middleware
            .handle(makeRequest(), body: Data(), now: now) { _, _ in
                (HTTPResponse(status: .ok), ran)
            }
        #expect(response.status.code == 402)
        #expect(body != ran)
    }

    @Test("a present credential skips the authorizer and takes the verify path")
    func credentialSkipsAuthorizer() async throws {
        // An authorizer that would short-circuit must be ignored when a credential is present.
        let stub = StubAuthorizer(outcome: .respond(
            HTTPResponse(status: .serviceUnavailable),
            Data()
        ))
        let middleware = try makeMiddleware(authorizer: stub)
        let request = try makeRequest(authorization: paidHeader())
        let (response, body) = await middleware
            .handle(request, body: Data(), now: now) { _, verified in
                #expect(verified.credential != nil) // verify path always has a credential
                return (HTTPResponse(status: .ok), ran)
            }
        #expect(response.status.code == 200)
        #expect(body == ran)
    }

    @Test("with no authorizer a credential-less request still gets a 402 (no bypass)")
    func noAuthorizerStill402() async throws {
        let middleware = try makeMiddleware()
        let (response, _) = await middleware.handle(makeRequest(), body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), ran)
        }
        #expect(response.status.code == 402)
    }

    @Test("the body cap is enforced before the authorizer runs")
    func bodyCapBeforeAuthorize() async throws {
        let stub = StubAuthorizer(outcome: .authorized(nil)) // would serve if reached
        let middleware = try makeMiddleware(maxBodyBytes: 16, authorizer: stub)
        let (response, body) = await middleware.handle(
            makeRequest(), body: Data(repeating: 0, count: 17), now: now
        ) { _, _ in (HTTPResponse(status: .ok), ran) }
        #expect(response.status.code == 413)
        #expect(body != ran)
    }

    @Test("the authorize path emits a paymentVerified event for observability parity")
    func authorizeEmitsEvent() async throws {
        let sink = EventSink()
        let middleware = try makeMiddleware(
            authorizer: StubAuthorizer(outcome: .authorized(receipt())),
            onEvent: { sink.add($0) }
        )
        _ = await middleware.handle(makeRequest(), body: Data(), now: now) { _, _ in
            (HTTPResponse(status: .ok), ran)
        }
        #expect(sink.verifiedCount == 1)
    }
}

/// A thread-safe sink for the middleware's synchronous `onEvent` callback.
private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ServerEvent] = []

    func add(_ event: ServerEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var verifiedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events
            .count(where: { if case .paymentVerified = $0 { return true } else { return false } })
    }
}
